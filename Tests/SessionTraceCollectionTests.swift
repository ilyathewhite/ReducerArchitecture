import Foundation
import Testing
@testable import ReducerArchitecture

extension SessionTraceTests {
    @Suite struct SessionTraceCollectionTests {}
}

extension SessionTraceTests.SessionTraceCollectionTests {
    private struct LegacyStoredSessionFixture: Codable {
        struct Entry: Codable {
            let key: String
            let payloadType: String
            let payload: Data
        }

        let title: String
        let entries: [Entry]
    }

    @Test
    func saveAndLoadRoundTripsSessionGraph() throws {
        let title = "session-trace-\(UUID().uuidString)"
        let graph = makeSessionGraph()
        let collection = SessionTraceCollection(title: title, sessionGraph: graph)

        let path = try #require(try collection.save())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let loaded = try SessionTraceCollection.load(from: URL(fileURLWithPath: path))
        #expect(loaded.title == title)
        #expect(loaded.sessionGraph == graph)
    }

    @Test
    func initWithInvalidCompressedDataThrows() {
        let invalidCompressedData = Data("not-a-session-trace".utf8)
        #expect(throws: (any Error).self) {
            try SessionTraceCollection(compressedData: invalidCompressedData)
        }
    }

    @Test
    func initSupportsLegacyCompressedCollectionFormat() throws {
        let collection = SessionTraceCollection(
            title: "legacy-session-trace",
            sessionGraph: makeSessionGraph()
        )
        let rawData = try JSONEncoder().encode(collection)
        let compressedData = try (rawData as NSData).compressed(using: .lzma) as Data

        let loaded = try SessionTraceCollection(compressedData: compressedData)
        #expect(loaded.title == collection.title)
        #expect(loaded.sessionGraph == collection.sessionGraph)
    }

    @Test
    func initFileDataSupportsRawJSONCollectionFormat() throws {
        let collection = SessionTraceCollection(
            title: "raw-json-session-trace",
            sessionGraph: makeSessionGraph()
        )
        let fileData = try JSONEncoder().encode(collection)

        let loaded = try SessionTraceCollection(fileData: fileData)
        #expect(loaded.title == collection.title)
        #expect(loaded.sessionGraph == collection.sessionGraph)
    }

    @Test
    func initFileDataSupportsCompressedGraphStorageFormat() throws {
        let collection = SessionTraceCollection(
            title: "compressed-session-trace",
            sessionGraph: makeSessionGraph()
        )
        let fileData = try saveAndReadBackCompressedDataForTest(collection)

        let loaded = try SessionTraceCollection(fileData: fileData)
        #expect(loaded.title == collection.title)
        #expect(loaded.sessionGraph == collection.sessionGraph)
    }

    @Test
    func initSupportsLegacySessionStorageCollectionFormat() throws {
        let graph = makeSessionGraph()
        let legacy = LegacyStoredSessionFixture(
            title: "legacy-session-storage",
            entries: [
                .init(
                    key: "SessionGraph.\(graph.storeInstanceID)",
                    payloadType: "SessionGraph",
                    payload: try JSONEncoder().encode(graph)
                )
            ]
        )
        let rawData = try JSONEncoder().encode(legacy)
        let compressedData = try (rawData as NSData).compressed(using: .lzma) as Data

        let loaded = try SessionTraceCollection(compressedData: compressedData)
        #expect(loaded.title == legacy.title)
        #expect(loaded.sessionGraph == graph)
    }

    @Test
    func initFileDataSupportsLegacySessionStorageCollectionFormat() throws {
        let graph = makeSessionGraph()
        let legacy = LegacyStoredSessionFixture(
            title: "legacy-session-storage",
            entries: [
                .init(
                    key: "SessionGraph.\(graph.storeInstanceID)",
                    payloadType: "SessionGraph",
                    payload: try JSONEncoder().encode(graph)
                )
            ]
        )
        let rawData = try JSONEncoder().encode(legacy)
        let fileData = try (rawData as NSData).compressed(using: .lzma) as Data

        let loaded = try SessionTraceCollection(fileData: fileData)
        #expect(loaded.title == legacy.title)
        #expect(loaded.sessionGraph == graph)
    }

    @Test
    func sessionInitFileDataRoundTripsSingleStoreSession() throws {
        let collection = SessionTraceCollection(
            title: "counter-store",
            sessionGraph: makeSessionGraph(storeInstanceID: "counter.s1")
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let session = TraceSession(
            sessionID: "session-a",
            title: "Example App",
            hostName: "Host A",
            processName: "Example App",
            startedAt: startedAt,
            storeTraces: [
                .init(
                    storeInstanceID: "counter.s1",
                    storeName: "CounterStore",
                    hostName: "Host A",
                    processName: "Example App",
                    startedAt: startedAt,
                    traceCollection: collection
                )
            ]
        )

        let fileData = try JSONEncoder().encode(session)
        let loaded = try TraceSession(fileData: fileData)

        #expect(loaded == session)
    }

    @Test
    func liveSessionAccumulatorCollectsMultipleStoreTracesIntoOneSession() {
        let firstCollection = SessionTraceCollection(
            title: "CounterStore",
            sessionGraph: makeSessionGraph(storeInstanceID: "counter.s1")
        )
        let secondCollection = SessionTraceCollection(
            title: "TimerStore",
            sessionGraph: makeSessionGraph(storeInstanceID: "timer.s2")
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var accumulator = LiveTraceSessionAccumulator(
            title: "Live Trace",
            sessionID: "session-a"
        )

        accumulator.apply(
            .hello(
                .init(
                    sessionID: "session-a",
                    storeInstanceID: "counter.s1",
                    title: "Example App",
                    storeName: "CounterStore",
                    hostName: "Host A",
                    processName: "Example App",
                    startedAt: startedAt
                )
            )
        )
        accumulator.apply(
            .snapshot(
                sessionID: "session-a",
                storeInstanceID: "counter.s1",
                traceCollection: firstCollection
            )
        )
        accumulator.apply(
            .hello(
                .init(
                    sessionID: "session-a",
                    storeInstanceID: "timer.s2",
                    title: "Example App",
                    storeName: "TimerStore",
                    hostName: "Host A",
                    processName: "Example App",
                    startedAt: startedAt.addingTimeInterval(5)
                )
            )
        )
        accumulator.apply(
            .snapshot(
                sessionID: "session-a",
                storeInstanceID: "timer.s2",
                traceCollection: secondCollection
            )
        )
        let secondEndedAt = startedAt.addingTimeInterval(10)
        accumulator.apply(
            .hello(
                .init(
                    sessionID: "session-a",
                    storeInstanceID: "timer.s2",
                    title: "Example App",
                    storeName: "TimerStore",
                    hostName: "Host A",
                    processName: "Example App",
                    startedAt: startedAt.addingTimeInterval(5),
                    endedAt: secondEndedAt
                )
            )
        )

        let session = accumulator.session

        #expect(session.title == "Example App")
        #expect(session.startedAt == startedAt)
        #expect(session.storeTraces.map(\.id) == ["counter.s1", "timer.s2"])
        #expect(session.storeTrace(id: "counter.s1")?.traceCollection == firstCollection)
        #expect(session.storeTrace(id: "timer.s2")?.traceCollection == secondCollection)
        #expect(session.storeTrace(id: "counter.s1")?.isEnded == false)
        #expect(session.storeTrace(id: "timer.s2")?.endedAt == secondEndedAt)
    }

    @Test
    func liveSessionAccumulatorAssignsNumberedNamesToDefaultStoreTypes() {
        var accumulator = LiveTraceSessionAccumulator(
            title: "Live Trace",
            sessionID: "session-a"
        )
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        accumulator.apply(
            .hello(
                .init(
                    sessionID: "session-a",
                    storeInstanceID: "SyncUpList.s1",
                    title: "Example App",
                    storeName: "SyncUpList",
                    hostName: "Host A",
                    processName: "Example App",
                    startedAt: startedAt
                )
            )
        )
        accumulator.apply(
            .hello(
                .init(
                    sessionID: "session-a",
                    storeInstanceID: "RecordMeeting.s2",
                    title: "Example App",
                    storeName: "RecordMeeting",
                    hostName: "Host A",
                    processName: "Example App",
                    startedAt: startedAt.addingTimeInterval(10)
                )
            )
        )
        accumulator.apply(
            .hello(
                .init(
                    sessionID: "session-a",
                    storeInstanceID: "RecordMeeting.s3",
                    title: "Example App",
                    storeName: "RecordMeeting",
                    hostName: "Host A",
                    processName: "Example App",
                    startedAt: startedAt.addingTimeInterval(20)
                )
            )
        )

        let session = accumulator.session

        #expect(session.storeTraces.map(\.displayName) == [
            "SyncUpList",
            "RecordMeeting",
            "RecordMeeting 2"
        ])
    }

    private func makeSessionGraph(
        storeInstanceID: String = "store.s1"
    ) -> SessionGraph {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let actionID: SessionGraph.ActionID = .init(rawValue: "\(storeInstanceID).a1")
        let mutationID: SessionGraph.MutationID = .init(rawValue: "\(storeInstanceID).m1")
        let actionNode = SessionGraph.ActionNode(
            id: actionID,
            order: 1,
            receivedAt: startDate,
            action: "mutating.update",
            actionCase: "update",
            kind: .mutating,
            source: .user,
            nestedLevel: 0,
            animationGroupID: nil,
            stateBefore: [],
            callSite: .init(file: "Feature.swift", line: 12),
            completedAt: startDate.addingTimeInterval(2),
            stateAfter: [],
            outputEffect: "none"
        )
        let mutationNode = SessionGraph.MutationNode(
            id: mutationID,
            order: 2,
            appliedAt: startDate.addingTimeInterval(1),
            actionID: actionID,
            nestedLevel: 0,
            before: [],
            after: [],
            propertyDiff: []
        )
        return SessionGraph(
            storeInstanceID: .init(rawValue: storeInstanceID),
            nodes: [.action(actionNode), .mutation(mutationNode)],
            edges: [
                .applied(
                    .init(order: 3, actionID: actionID, mutationID: mutationID)
                )
            ]
        )
    }

    private func saveAndReadBackCompressedDataForTest(
        _ collection: SessionTraceCollection
    ) throws -> Data {
        let path = try #require(try collection.save())
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }
}
