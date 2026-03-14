import Foundation
@testable import ReducerArchitecture

@MainActor
func liveTraceCollectionTask<Nsp: StoreNamespace>(
    for store: Nsp.Store
) -> Task<SessionTraceCollection, Error> {
    let collector = LiveTraceEnvelopeCollector()
    configureLiveTraceForTests(store: store, collector: collector)
    return Task {
        try await collector.waitForFirstStableCollection()
    }
}

@MainActor
func liveTraceEnvelopeCollector<Nsp: StoreNamespace>(
    for store: Nsp.Store
) -> LiveTraceEnvelopeCollector {
    let collector = LiveTraceEnvelopeCollector()
    configureLiveTraceForTests(store: store, collector: collector)
    return collector
}

@MainActor
private func configureLiveTraceForTests<Nsp: StoreNamespace>(
    store: Nsp.Store,
    collector: LiveTraceEnvelopeCollector
) {
    let originalConfig = LiveTraceConfig.shared
    collector.setOriginalConfig(originalConfig)
    resetLiveTraceRuntimeForTests()

    var config = originalConfig
    config.networkEnabled = false
    config.envelopeHandler = { [weak collector] envelope in
        collector?.receive(envelope)
    }
    LiveTraceConfig.shared = config
    store.logConfig.liveTraceEnabled = true
}

final class LiveTraceEnvelopeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionOrder: [String] = []
    private var accumulators: [String: LiveTraceSessionAccumulator] = [:]
    private var originalConfig: LiveTraceConfig?

    @MainActor
    func setOriginalConfig(_ config: LiveTraceConfig) {
        originalConfig = config
    }

    deinit {
        guard let originalConfig else { return }
        Task { @MainActor in
            LiveTraceConfig.shared = originalConfig
        }
    }

    func receive(_ envelope: LiveTraceEnvelope) {
        lock.lock()
        defer { lock.unlock() }

        var accumulator = accumulators[envelope.sessionID] ?? {
            sessionOrder.append(envelope.sessionID)
            return .init(
                title: "Live Trace",
                sessionID: envelope.sessionID
            )
        }()
        accumulator.apply(envelope)
        accumulators[envelope.sessionID] = accumulator
    }

    func waitForFirstStableCollection(
        timeout: Duration = .seconds(1)
    ) async throws -> SessionTraceCollection {
        let session = try await waitForFirstStableSession(timeout: timeout)
        guard let collection = session.firstStoreTrace?.traceCollection else {
            throw NSError(
                domain: "ReducerArchitectureTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for live trace collection."]
            )
        }
        return collection
    }

    func waitForFirstStableSession(
        timeout: Duration = .seconds(1),
        where predicate: (TraceSession) -> Bool = { _ in true }
    ) async throws -> TraceSession {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastSignature: (Int, Int)?
        var stableSamples = 0

        while clock.now < deadline {
            if let session = firstSession() {
                let signature = (
                    session.storeTraces.reduce(0) { $0 + $1.traceCollection.sessionGraph.nodes.count },
                    session.storeTraces.reduce(0) { $0 + $1.traceCollection.sessionGraph.edges.count }
                )
                if signature.0 > 0 {
                    if lastSignature?.0 == signature.0 && lastSignature?.1 == signature.1 {
                        stableSamples += 1
                    }
                    else {
                        lastSignature = signature
                        stableSamples = 0
                    }

                    if stableSamples >= 3 && predicate(session) {
                        return session
                    }
                }
            }

            try await Task.sleep(for: .milliseconds(10))
        }

        throw NSError(
            domain: "ReducerArchitectureTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for live trace collection."]
        )
    }

    private func firstCollection() -> SessionTraceCollection? {
        firstSession()?.firstStoreTrace?.traceCollection
    }

    private func firstSession() -> TraceSession? {
        lock.lock()
        defer { lock.unlock() }

        guard let sessionID = sessionOrder.first,
              let accumulator = accumulators[sessionID] else {
            return nil
        }
        return accumulator.session
    }
}
