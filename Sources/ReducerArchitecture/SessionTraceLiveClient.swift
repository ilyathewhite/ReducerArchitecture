//  SessionTraceLiveClient.swift
//  Created by Ilya Belenkiy on 3/3/26.

import Foundation
import os
#if canImport(Network)
import Network
#endif

#if canImport(Network)
final class SessionTraceLiveClient: @unchecked Sendable {
    private let sessionID: String
    private let config: SessionTraceLiveConfig
    private let metadata: SessionTraceLiveSessionMetadata
    private let logger: Logger
    private let queue: DispatchQueue

    private var connection: NWConnection?
    private var isReady = false
    private var handshakeInProgress = false
    private var shouldKeepRunning = true
    private var reconnectWorkItem: DispatchWorkItem?
    private var pendingPatches: [SessionTraceLivePatch] = []
    private var isSendingPatch = false
    private var hasLoggedDroppedPatchWarning = false

    init(
        sessionID: String,
        config: SessionTraceLiveConfig,
        metadata: SessionTraceLiveSessionMetadata,
        logger: Logger
    ) {
        self.sessionID = sessionID
        self.config = config
        self.metadata = metadata
        self.logger = logger
        self.queue = DispatchQueue(label: "ReducerArchitecture.SessionTraceLiveClient.\(sessionID)")
        queue.async { [weak self] in
            self?.connectIfNeeded()
        }
    }

    func record(_ patch: SessionTraceLivePatch) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.shouldKeepRunning else { return }

            self.enqueue(patch)
            self.connectIfNeeded()
            self.drainPendingPatchesIfPossible()
        }
    }

    func endSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldKeepRunning = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil

            if self.isReady, !self.handshakeInProgress, !self.isSendingPatch {
                self.send(.end(sessionID: self.sessionID)) { [weak self] in
                    self?.connection?.cancel()
                    self?.connection = nil
                    self?.isReady = false
                    self?.handshakeInProgress = false
                }
            }
            else {
                self.connection?.cancel()
                self.connection = nil
                self.isReady = false
                self.handshakeInProgress = false
                self.isSendingPatch = false
            }
        }
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
            self?.handle(state: state)
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            startHandshake()

        case .failed(let error):
            logger.debug("Live trace connection failed: \(String(describing: error), privacy: .public)")
            markDisconnectedAndReconnect()

        case .waiting(let error):
            logger.debug("Live trace connection waiting: \(String(describing: error), privacy: .public)")
            markDisconnectedAndReconnect()

        case .cancelled:
            connection = nil
            isReady = false
            handshakeInProgress = false
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
        connection?.cancel()
        connection = nil
        isReady = false
        handshakeInProgress = false
        isSendingPatch = false
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard shouldKeepRunning else { return }
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.connectIfNeeded()
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(deadline: .now() + config.reconnectDelay, execute: workItem)
    }

    private func startHandshake() {
        guard shouldKeepRunning else { return }
        handshakeInProgress = true
        send(.hello(metadata)) { [weak self] in
            guard let self else { return }
            self.handshakeInProgress = false
            self.drainPendingPatchesIfPossible()
        }
    }

    private func enqueue(_ patch: SessionTraceLivePatch) {
        pendingPatches.append(patch)
        guard pendingPatches.count > config.patchBufferCapacity else { return }

        pendingPatches.removeFirst(pendingPatches.count - config.patchBufferCapacity)
        if !hasLoggedDroppedPatchWarning {
            logger.warning(
                "Live trace patch buffer overflowed for \(self.sessionID, privacy: .public); older patches were dropped."
            )
            hasLoggedDroppedPatchWarning = true
        }
    }

    private func drainPendingPatchesIfPossible() {
        guard shouldKeepRunning else { return }
        guard isReady else { return }
        guard !handshakeInProgress else { return }
        guard !isSendingPatch else { return }
        guard let patch = pendingPatches.first else { return }

        isSendingPatch = true
        send(
            .patch(
                sessionID: sessionID,
                patch: patch
            )
        ) { [weak self] in
            guard let self else { return }
            self.isSendingPatch = false
            if !self.pendingPatches.isEmpty {
                self.pendingPatches.removeFirst()
            }
            self.drainPendingPatchesIfPossible()
        }
    }

    private func send(
        _ envelope: SessionTraceLiveEnvelope,
        completion: (() -> Void)? = nil
    ) {
        guard let connection else { return }
        do {
            let data = try SessionTraceLiveCodec.encode(envelope)
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.logger.debug("Live trace send failed: \(String(describing: error), privacy: .public)")
                    self.markDisconnectedAndReconnect()
                }
                else {
                    completion?()
                }
            })
        }
        catch {
            logger.error("Failed to encode live trace payload: \(String(describing: error), privacy: .public)")
        }
    }
}
#else
final class SessionTraceLiveClient {
    init(
        sessionID: String,
        config: SessionTraceLiveConfig,
        metadata: SessionTraceLiveSessionMetadata,
        logger: Logger
    ) {}

    func record(_ patch: SessionTraceLivePatch) {}

    func endSession() {}
}
#endif
