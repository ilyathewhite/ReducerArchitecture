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

    private func makeSessionGraph() -> SessionGraph {
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let actionNode = SessionGraph.ActionNode(
            id: "store.s1.a1",
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
            id: "store.s1.m1",
            order: 2,
            appliedAt: startDate.addingTimeInterval(1),
            actionID: "store.s1.a1",
            nestedLevel: 0,
            before: [],
            after: [],
            propertyDiff: []
        )
        return SessionGraph(
            storeInstanceID: "store.s1",
            nodes: [.action(actionNode), .mutation(mutationNode)],
            edges: [
                .applied(
                    .init(order: 3, actionID: "store.s1.a1", mutationID: "store.s1.m1")
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
