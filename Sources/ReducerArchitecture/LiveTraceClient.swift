//  LiveTraceClient.swift
//  Created by Ilya Belenkiy on 3/3/26.

import Foundation
import Network
import os

private enum LiveTraceSocketProbeResult {
    case reachable
    case unreachable
    case failed(String)
}

private struct LiveTraceSocketProbe {
    private static let queue = DispatchQueue(
        label: "ReducerArchitecture.LiveTraceSocketProbe",
        qos: .utility
    )

    static func failureMessage(
        host: String,
        port: UInt16,
        timeout: TimeInterval
    ) async -> String? {
        let result = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: performProbe(
                        host: host,
                        port: port,
                        timeout: timeout
                    )
                )
            }
        }

        switch result {
        case .reachable:
            return nil
        case .unreachable:
            return """
            Live trace viewer is not connected at \(host):\(port). \
            Start SessionTraceViewer before launching the app to capture live traces.
            """
        case .failed(let reason):
            return "Live trace could not connect to \(host):\(port): \(reason)"
        }
    }

    private static func performProbe(
        host: String,
        port: UInt16,
        timeout: TimeInterval
    ) -> LiveTraceSocketProbeResult {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var addressInfo: UnsafeMutablePointer<addrinfo>?
        let lookupResult = getaddrinfo(host, String(port), &hints, &addressInfo)
        guard lookupResult == 0 else {
            let message = String(cString: gai_strerror(lookupResult))
            return .failed(message)
        }
        defer { freeaddrinfo(addressInfo) }

        var currentAddress = addressInfo
        var sawUnreachableEndpoint = false
        var firstFailureMessage: String?

        while let current = currentAddress {
            let result = connect(
                using: current.pointee,
                timeout: timeout
            )
            switch result {
            case .reachable:
                return .reachable
            case .unreachable:
                sawUnreachableEndpoint = true
            case .failed(let reason):
                if firstFailureMessage == nil {
                    firstFailureMessage = reason
                }
            }

            currentAddress = current.pointee.ai_next
        }

        if sawUnreachableEndpoint {
            return .unreachable
        }
        return .failed(firstFailureMessage ?? "No reachable addresses were returned.")
    }

    private static func connect(
        using addressInfo: addrinfo,
        timeout: TimeInterval
    ) -> LiveTraceSocketProbeResult {
        let socketDescriptor = socket(
            addressInfo.ai_family,
            addressInfo.ai_socktype,
            addressInfo.ai_protocol
        )
        guard socketDescriptor >= 0 else {
            return .failed(socketErrorDescription(errno))
        }
        defer { Darwin.close(socketDescriptor) }

        let flags = fcntl(socketDescriptor, F_GETFL, 0)
        guard flags >= 0 else {
            return .failed(socketErrorDescription(errno))
        }
        guard fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return .failed(socketErrorDescription(errno))
        }

        let connectResult = Darwin.connect(
            socketDescriptor,
            addressInfo.ai_addr,
            addressInfo.ai_addrlen
        )
        if connectResult == 0 {
            return .reachable
        }

        let connectError = errno
        if connectError != EINPROGRESS {
            return isUnreachableSocketError(connectError)
                ? .unreachable
                : .failed(socketErrorDescription(connectError))
        }

        var pollDescriptor = pollfd(
            fd: socketDescriptor,
            events: Int16(POLLOUT),
            revents: 0
        )
        let timeoutMilliseconds = Int32(max(1, Int((max(0.25, timeout)) * 1000)))
        let pollResult = withUnsafeMutablePointer(to: &pollDescriptor) {
            Darwin.poll($0, 1, timeoutMilliseconds)
        }

        if pollResult == 0 {
            return .unreachable
        }
        if pollResult < 0 {
            return .failed(socketErrorDescription(errno))
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let socketOptionResult = withUnsafeMutablePointer(to: &socketError) {
            getsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_ERROR,
                $0,
                &socketErrorLength
            )
        }

        guard socketOptionResult == 0 else {
            return .failed(socketErrorDescription(errno))
        }
        if socketError == 0 {
            return .reachable
        }
        return isUnreachableSocketError(socketError)
            ? .unreachable
            : .failed(socketErrorDescription(socketError))
    }

    private static func isUnreachableSocketError(_ errorCode: Int32) -> Bool {
        switch errorCode {
        case ECONNREFUSED, ECONNRESET, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH,
             ETIMEDOUT, EADDRNOTAVAIL:
            return true
        default:
            return false
        }
    }

    private static func socketErrorDescription(_ errorCode: Int32) -> String {
        String(cString: strerror(errorCode))
    }
}

actor LiveTraceClient {
    private let sessionID: String
    private let config: LiveTraceConfig
    private let logger: Logger
    private let queue: DispatchQueue
    private let connectivityProbe: @Sendable (String, UInt16, TimeInterval) async -> String?
    private let diagnosticSink: (@Sendable (String) -> Void)?

    private var connection: NWConnection?
    private var isReady = false
    private var shouldKeepRunning = true
    private var connectTask: Task<Void, Never>?
    private var metadataByStoreID: [String: LiveTraceStoreMetadata] = [:]
    private var announcedStoreIDs: Set<String> = []
    private var pendingHelloStoreIDs: [String] = []
    private var pendingPatches: [LiveTraceEnvelope] = []
    private var sendingHelloStoreID: String?
    private var isSendingPatch = false
    private var hasLoggedDroppedPatchWarning = false
    private var hasReportedConnectivityIssue = false

    init(
        sessionID: String,
        config: LiveTraceConfig,
        logger: Logger,
        connectivityProbe: @escaping @Sendable (String, UInt16, TimeInterval) async -> String? = { host, port, timeout in
            await LiveTraceSocketProbe.failureMessage(
                host: host,
                port: port,
                timeout: timeout
            )
        },
        diagnosticSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.config = config
        self.logger = logger
        self.connectivityProbe = connectivityProbe
        self.diagnosticSink = diagnosticSink
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
        connectTask?.cancel()
        connectTask = nil
        cancelConnection()
    }

    private func connectIfNeeded() {
        guard shouldKeepRunning else { return }
        guard connection == nil else { return }
        guard connectTask == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: config.port) else {
            stopAfterConnectivityFailure(
                "Live trace is misconfigured: invalid port \(config.port)."
            )
            return
        }

        connectTask = Task { [weak self] in
            await self?.performConnectionAttempt(port: nwPort)
        }
    }

    private func performConnectionAttempt(port: NWEndpoint.Port) async {
        defer { connectTask = nil }

        let failureMessage = await connectivityProbe(
            config.host,
            config.port,
            connectionProbeTimeout
        )

        guard shouldKeepRunning else { return }
        guard connection == nil else { return }

        if let failureMessage {
            stopAfterConnectivityFailure(failureMessage)
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
            hasReportedConnectivityIssue = false
            queueReconnectHellos()
            drainPendingEnvelopesIfPossible()

        case .failed:
            stopAfterConnectivityFailure(viewerDisconnectedMessage())

        case .waiting:
            stopAfterConnectivityFailure(viewerDisconnectedMessage())

        case .cancelled:
            cancelConnection()

        case .setup, .preparing:
            break

        @unknown default:
            break
        }
    }

    private func stopAfterConnectivityFailure(_ message: String) {
        reportConnectivityIssueIfNeeded(message)
        shouldKeepRunning = false
        connectTask?.cancel()
        connectTask = nil
        metadataByStoreID = [:]
        announcedStoreIDs = []
        pendingHelloStoreIDs = []
        pendingPatches = []
        cancelConnection()
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
        _ = error
        stopAfterConnectivityFailure(viewerDisconnectedMessage())
    }

    private var connectionProbeTimeout: TimeInterval {
        0.25
    }

    private func viewerDisconnectedMessage() -> String {
        """
        Live trace viewer is not connected at \(config.host):\(config.port). \
        Start SessionTraceViewer before launching the app to capture live traces.
        """
    }

    private func reportConnectivityIssueIfNeeded(_ message: String) {
        guard !hasReportedConnectivityIssue else { return }
        hasReportedConnectivityIssue = true
        if let diagnosticSink {
            diagnosticSink(message)
        }
        else {
            logger.fault("\(message, privacy: .public)")
        }
    }

    private func cancelConnection() {
        connection?.cancel()
        connection = nil
        isReady = false
        sendingHelloStoreID = nil
        isSendingPatch = false
    }
}
