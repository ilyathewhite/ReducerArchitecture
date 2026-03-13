//  LiveTraceClient.swift
//  Created by Ilya Belenkiy on 3/3/26.

import Foundation
import Network
import os

actor LiveTraceClient {
    private let sessionID: String
    private let config: LiveTraceConfig
    private let logger: Logger
    private let queue: DispatchQueue

    private var connection: NWConnection?
    private var isReady = false
    private var shouldKeepRunning = true
    private var reconnectTask: Task<Void, Never>?
    private var metadataByStoreID: [String: LiveTraceStoreMetadata] = [:]
    private var announcedStoreIDs: Set<String> = []
    private var pendingHelloStoreIDs: [String] = []
    private var pendingPatches: [LiveTraceEnvelope] = []
    private var sendingHelloStoreID: String?
    private var isSendingPatch = false
    private var hasLoggedDroppedPatchWarning = false

    init(
        sessionID: String,
        config: LiveTraceConfig,
        logger: Logger
    ) {
        self.sessionID = sessionID
        self.config = config
        self.logger = logger
        self.queue = DispatchQueue(
            label: "ReducerArchitecture.LiveTraceClient.\(sessionID)"
        )
    }

    func updateStoreMetadata(_ metadata: LiveTraceStoreMetadata) {
        guard shouldKeepRunning else { return }

        let storeInstanceID = metadata.storeInstanceID
        if metadataByStoreID[storeInstanceID] != metadata {
            announcedStoreIDs.remove(storeInstanceID)
            pendingHelloStoreIDs.removeAll(where: { $0 == storeInstanceID })
        }
        metadataByStoreID[storeInstanceID] = metadata
        enqueueHelloIfNeeded(for: storeInstanceID)
        connectIfNeeded()
        drainPendingEnvelopesIfPossible()
    }

    func record(
        _ patch: LiveTracePatch,
        metadata: LiveTraceStoreMetadata
    ) {
        guard shouldKeepRunning else { return }

        updateStoreMetadata(metadata)
        enqueue(patch, storeInstanceID: metadata.storeInstanceID)
        drainPendingEnvelopesIfPossible()
    }

    func stop() {
        shouldKeepRunning = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelConnection()
    }

    private func connectIfNeeded() {
        guard shouldKeepRunning else { return }
        guard connection == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            logger.error("Invalid live trace port \(self.config.port, privacy: .public)")
            return
        }

        let connection = NWConnection(
            host: .init(config.host),
            port: port,
            using: .tcp
        )
        connection.stateUpdateHandler = { [weak self] state in
            Task {
                await self?.handle(state: state)
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            reconnectTask?.cancel()
            reconnectTask = nil
            queueReconnectHellos()
            drainPendingEnvelopesIfPossible()

        case .failed(let error):
            logger.debug("Live trace connection failed: \(String(describing: error), privacy: .public)")
            markDisconnectedAndReconnect()

        case .waiting(let error):
            logger.debug("Live trace connection waiting: \(String(describing: error), privacy: .public)")
            markDisconnectedAndReconnect()

        case .cancelled:
            cancelConnection()
            if shouldKeepRunning {
                scheduleReconnect()
            }

        case .setup, .preparing:
            break

        @unknown default:
            break
        }
    }

    private func markDisconnectedAndReconnect() {
        cancelConnection()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldKeepRunning else { return }
        reconnectTask?.cancel()

        let delayNanoseconds = UInt64(max(0, config.reconnectDelay) * 1_000_000_000)
        reconnectTask = Task { [weak self] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self?.reconnectIfNeeded()
        }
    }

    private func reconnectIfNeeded() {
        reconnectTask = nil
        connectIfNeeded()
    }

    private func queueReconnectHellos() {
        announcedStoreIDs.removeAll()
        pendingHelloStoreIDs = metadataByStoreID.keys.sorted()
    }

    private func enqueueHelloIfNeeded(for storeInstanceID: String) {
        guard !announcedStoreIDs.contains(storeInstanceID) else { return }
        guard !pendingHelloStoreIDs.contains(storeInstanceID) else { return }
        pendingHelloStoreIDs.append(storeInstanceID)
    }

    private func enqueue(
        _ patch: LiveTracePatch,
        storeInstanceID: String
    ) {
        pendingPatches.append(
            .patch(
                sessionID: sessionID,
                storeInstanceID: storeInstanceID,
                patch: patch
            )
        )
        guard pendingPatches.count > config.patchBufferCapacity else { return }

        pendingPatches.removeFirst(pendingPatches.count - config.patchBufferCapacity)
        if !hasLoggedDroppedPatchWarning {
            logger.warning(
                "Live trace patch buffer overflowed for \(self.sessionID, privacy: .public); older patches were dropped."
            )
            hasLoggedDroppedPatchWarning = true
        }
    }

    private func drainPendingEnvelopesIfPossible() {
        guard shouldKeepRunning else { return }
        guard isReady else { return }
        guard sendingHelloStoreID == nil else { return }
        guard !isSendingPatch else { return }

        if let storeInstanceID = pendingHelloStoreIDs.first,
           let metadata = metadataByStoreID[storeInstanceID] {
            sendingHelloStoreID = storeInstanceID
            send(.hello(metadata)) { [weak self] didSendHello in
                Task {
                    await self?.finishSendingHello(
                        storeInstanceID: storeInstanceID,
                        didSendHello: didSendHello
                    )
                }
            }
            return
        }

        guard let envelope = pendingPatches.first else { return }

        isSendingPatch = true
        send(envelope) { [weak self] didSendPatch in
            Task {
                await self?.finishSendingPatch(didSendPatch: didSendPatch)
            }
        }
    }

    private func finishSendingHello(
        storeInstanceID: String,
        didSendHello: Bool
    ) {
        sendingHelloStoreID = nil
        if didSendHello {
            pendingHelloStoreIDs.removeAll(where: { $0 == storeInstanceID })
            announcedStoreIDs.insert(storeInstanceID)
        }
        drainPendingEnvelopesIfPossible()
    }

    private func finishSendingPatch(didSendPatch: Bool) {
        isSendingPatch = false
        if didSendPatch, !pendingPatches.isEmpty {
            pendingPatches.removeFirst()
        }
        drainPendingEnvelopesIfPossible()
    }

    private func send(
        _ envelope: LiveTraceEnvelope,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        guard let connection else {
            completion?(false)
            return
        }
        do {
            let data = try LiveTraceCodec.encode(envelope)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task {
                        await self?.handleSendFailure(error)
                    }
                    completion?(false)
                }
                else {
                    completion?(true)
                }
            })
        }
        catch {
            logger.error("Failed to encode live trace payload: \(String(describing: error), privacy: .public)")
            completion?(false)
        }
    }

    private func handleSendFailure(_ error: NWError) {
        logger.debug("Live trace send failed: \(String(describing: error), privacy: .public)")
        markDisconnectedAndReconnect()
    }

    private func cancelConnection() {
        connection?.cancel()
        connection = nil
        isReady = false
        sendingHelloStoreID = nil
        isSendingPatch = false
    }
}
