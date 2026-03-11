import Foundation
@testable import ReducerArchitecture

@MainActor
func liveTraceCollectionTask<Nsp: StoreNamespace>(
    for store: Nsp.Store
) -> Task<SessionTraceCollection, Error> {
    let collector = SessionTraceEnvelopeCollector()
    store.logConfig.liveTraceHandler = { envelope in
        collector.receive(envelope)
    }
    return Task {
        try await collector.waitForFirstStableCollection()
    }
}

@MainActor
func liveTraceEnvelopeCollector<Nsp: StoreNamespace>(
    for store: Nsp.Store
) -> SessionTraceEnvelopeCollector {
    let collector = SessionTraceEnvelopeCollector()
    store.logConfig.liveTraceHandler = { envelope in
        collector.receive(envelope)
    }
    return collector
}

final class SessionTraceEnvelopeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionOrder: [String] = []
    private var accumulators: [String: SessionTraceLiveAccumulator] = [:]
    private var endedSessionIDs: Set<String> = []

    func receive(_ envelope: SessionTraceLiveEnvelope) {
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
        if envelope.kind == .end {
            endedSessionIDs.insert(envelope.sessionID)
        }
    }

    func waitForFirstStableCollection(
        timeout: Duration = .seconds(1)
    ) async throws -> SessionTraceCollection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var lastSignature: (Int, Int)?
        var stableSamples = 0

        while clock.now < deadline {
            if let collection = firstCollection() {
                let signature = (
                    collection.sessionGraph.nodes.count,
                    collection.sessionGraph.edges.count
                )
                if signature.0 > 0 {
                    if lastSignature?.0 == signature.0 && lastSignature?.1 == signature.1 {
                        stableSamples += 1
                    }
                    else {
                        lastSignature = signature
                        stableSamples = 0
                    }

                    if stableSamples >= 3 {
                        return collection
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

    func waitForEnd(
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if hasEndedFirstSession() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        throw NSError(
            domain: "ReducerArchitectureTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for live trace end envelope."]
        )
    }

    private func firstCollection() -> SessionTraceCollection? {
        lock.lock()
        defer { lock.unlock() }

        guard let sessionID = sessionOrder.first,
              let accumulator = accumulators[sessionID] else {
            return nil
        }
        return accumulator.traceCollection
    }

    private func hasEndedFirstSession() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let sessionID = sessionOrder.first else { return false }
        return endedSessionIDs.contains(sessionID)
    }
}
