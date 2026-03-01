//
//  ReducerArchitectureSessionTracePersistence.swift
//
//  Created by Ilya Belenkiy on 2/25/26.
//

import Foundation
import GraphStorage

private enum SessionTraceStorageError: Error {
    case unsupportedNodeKind(String)
    case unsupportedEdgeKind(String)
    case missingLegacySessionGraph
    case duplicateLegacySessionGraphs(count: Int)
}

private struct LegacyStoredSession: Codable {
    struct Entry: Codable {
        let key: String
        let payloadType: String
        let payload: Data

        func decodePayload<Value: Decodable>(
            as valueType: Value.Type,
            decoder: JSONDecoder = JSONDecoder()
        ) throws -> Value {
            try decoder.decode(valueType, from: payload)
        }
    }

    let title: String
    let entries: [Entry]
}

public struct SessionTraceCollection: Codable {
    public let title: String
    public let sessionGraph: SessionGraph

    private static let titleMetadataKey = "SessionTraceCollection.title"
    private static let storeInstanceIDMetadataKey = "SessionGraph.storeInstanceID"
    private static let legacySessionGraphPayloadType = "SessionGraph"

    private static let stateNodePayloadType = "SessionGraph.StateNode"
    private static let actionNodePayloadType = "SessionGraph.ActionNode"
    private static let mutationNodePayloadType = "SessionGraph.MutationNode"
    private static let effectNodePayloadType = "SessionGraph.EffectNode"
    private static let batchNodePayloadType = "SessionGraph.BatchNode"

    private static let stateInputEdgePayloadType = "SessionGraph.StateInputEdge"
    private static let stateResultEdgePayloadType = "SessionGraph.StateResultEdge"
    private static let appliedEdgePayloadType = "SessionGraph.AppliedEdge"
    private static let startedEffectEdgePayloadType = "SessionGraph.StartedEffectEdge"
    private static let emittedActionEdgePayloadType = "SessionGraph.EmittedActionEdge"
    private static let producedActionEdgePayloadType = "SessionGraph.ProducedActionEdge"
    private static let containsEdgePayloadType = "SessionGraph.ContainsEdge"
    private static let nestedEdgePayloadType = "SessionGraph.NestedEdge"

    public init(
        title: String,
        sessionGraph: SessionGraph
    ) {
        self.title = title
        self.sessionGraph = sessionGraph
    }

    enum CodingKeys: String, CodingKey {
        case title
        case sessionGraph
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        sessionGraph = try container.decode(SessionGraph.self, forKey: .sessionGraph)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(sessionGraph, forKey: .sessionGraph)
    }

    public init(compressedData: Data) throws {
        if let storedGraph = try? GraphStorageCodec.decodeCompressed(
            StoredGraph.self,
            from: compressedData
        ) {
            self = try .init(storedGraph: storedGraph)
            return
        }

        if let legacyStoredSession = try? GraphStorageCodec.decodeCompressed(
            LegacyStoredSession.self,
            from: compressedData
        ) {
            self = try .init(legacyStoredSession: legacyStoredSession)
            return
        }

        // Backward compatibility for traces saved before GraphStorage migration.
        self = try GraphStorageCodec.decodeCompressed(Self.self, from: compressedData)
    }

    public init(fileData: Data) throws {
        if let compressed = try? Self(compressedData: fileData) {
            self = compressed
            return
        }

        self = try JSONDecoder().decode(Self.self, from: fileData)
    }

    public static func load(from url: URL) throws -> Self {
        let compressedData = try Data(contentsOf: url)
        return try .init(compressedData: compressedData)
    }

    public func save() throws -> String? {
        let fileManager = FileManager.default
        let rootFolderURL = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )

        let logFolderURL = rootFolderURL.appendingPathComponent("ReducerLogs")
        if !fileManager.fileExists(atPath: logFolderURL.relativePath) {
            try fileManager.createDirectory(
                at: logFolderURL,
                withIntermediateDirectories: false,
                attributes: nil
            )
        }

        let logURL = logFolderURL
            .appendingPathComponent("\(title)", conformingTo: .data)
            .appendingPathExtension(Self.dataExtension)

        let storedGraph = try toStoredGraph()
        let compressedData = try GraphStorageCodec.encodeCompressed(storedGraph)

        if FileManager.default.createFile(atPath: logURL.relativePath, contents: compressedData) {
            return logURL.relativePath
        }
        else {
            return nil
        }
    }

    private init(storedGraph: StoredGraph) throws {
        title = try storedGraph.requiredSingleMetadataValue(key: Self.titleMetadataKey)
        let storeInstanceID = try storedGraph.requiredSingleMetadataValue(
            key: Self.storeInstanceIDMetadataKey
        )

        let nodes = try storedGraph.nodes.map(Self.sessionGraphNode(from:))
        let edges = try storedGraph.edges.map(Self.sessionGraphEdge(from:))

        sessionGraph = .init(
            storeInstanceID: .init(rawValue: storeInstanceID),
            nodes: nodes,
            edges: edges
        )
    }

    private init(legacyStoredSession: LegacyStoredSession) throws {
        let graphEntries = legacyStoredSession.entries
            .filter { $0.payloadType == Self.legacySessionGraphPayloadType }

        guard let graphEntry = graphEntries.first else {
            throw SessionTraceStorageError.missingLegacySessionGraph
        }

        guard graphEntries.count == 1 else {
            throw SessionTraceStorageError.duplicateLegacySessionGraphs(count: graphEntries.count)
        }

        self.init(
            title: legacyStoredSession.title,
            sessionGraph: try graphEntry.decodePayload(as: SessionGraph.self)
        )
    }

    private func toStoredGraph() throws -> StoredGraph {
        let metadata: [StoredGraph.Metadata] = [
            .init(key: Self.titleMetadataKey, value: title),
            .init(key: Self.storeInstanceIDMetadataKey, value: sessionGraph.storeInstanceID.rawValue)
        ]

        let nodes = try sessionGraph.nodes.map(Self.storedNode(from:))
        let edges = try sessionGraph.edges.map(Self.storedEdge(from:))

        return .init(
            metadata: metadata,
            nodes: nodes,
            edges: edges
        )
    }

    private static func sessionGraphNode(
        from storedNode: StoredGraph.Node
    ) throws -> SessionGraph.Node {
        switch storedNode.kind {
        case "state":
            return .state(try storedNode.decodePayload(as: SessionGraph.StateNode.self))
        case "action":
            return .action(try storedNode.decodePayload(as: SessionGraph.ActionNode.self))
        case "mutation":
            return .mutation(try storedNode.decodePayload(as: SessionGraph.MutationNode.self))
        case "effect":
            return .effect(try storedNode.decodePayload(as: SessionGraph.EffectNode.self))
        case "batch":
            return .batch(try storedNode.decodePayload(as: SessionGraph.BatchNode.self))
        default:
            throw SessionTraceStorageError.unsupportedNodeKind(storedNode.kind)
        }
    }

    private static func storedNode(
        from node: SessionGraph.Node
    ) throws -> StoredGraph.Node {
        switch node {
        case .state(let state):
            return try .init(
                id: state.id.rawValue,
                kind: "state",
                order: state.order,
                payloadType: Self.stateNodePayloadType,
                payload: state
            )

        case .action(let action):
            return try .init(
                id: action.id.rawValue,
                kind: "action",
                order: action.order,
                payloadType: Self.actionNodePayloadType,
                payload: action
            )

        case .mutation(let mutation):
            return try .init(
                id: mutation.id.rawValue,
                kind: "mutation",
                order: mutation.order,
                payloadType: Self.mutationNodePayloadType,
                payload: mutation
            )

        case .effect(let effect):
            return try .init(
                id: effect.id.rawValue,
                kind: "effect",
                order: effect.order,
                payloadType: Self.effectNodePayloadType,
                payload: effect
            )

        case .batch(let batch):
            return try .init(
                id: batch.id.rawValue,
                kind: "batch",
                order: batch.order,
                payloadType: Self.batchNodePayloadType,
                payload: batch
            )
        }
    }

    private static func sessionGraphEdge(
        from storedEdge: StoredGraph.Edge
    ) throws -> SessionGraph.Edge {
        switch storedEdge.kind {
        case "stateInput":
            return .stateInput(try storedEdge.decodePayload(as: SessionGraph.StateInputEdge.self))
        case "stateResult":
            return .stateResult(try storedEdge.decodePayload(as: SessionGraph.StateResultEdge.self))
        case "applied":
            return .applied(try storedEdge.decodePayload(as: SessionGraph.AppliedEdge.self))
        case "startedEffect":
            return .startedEffect(
                try storedEdge.decodePayload(as: SessionGraph.StartedEffectEdge.self)
            )
        case "emittedAction":
            return .emittedAction(
                try storedEdge.decodePayload(as: SessionGraph.EmittedActionEdge.self)
            )
        case "producedAction":
            return .producedAction(
                try storedEdge.decodePayload(as: SessionGraph.ProducedActionEdge.self)
            )
        case "contains":
            return .contains(try storedEdge.decodePayload(as: SessionGraph.ContainsEdge.self))
        case "nested":
            return .nested(try storedEdge.decodePayload(as: SessionGraph.NestedEdge.self))
        default:
            throw SessionTraceStorageError.unsupportedEdgeKind(storedEdge.kind)
        }
    }

    private static func storedEdge(
        from edge: SessionGraph.Edge
    ) throws -> StoredGraph.Edge {
        switch edge {
        case .stateInput(let stateInput):
            return try .init(
                id: edgeID(kind: "stateInput", order: stateInput.order),
                kind: "stateInput",
                order: stateInput.order,
                fromNodeId: stateInput.stateID.rawValue,
                toNodeId: stateInput.actionID.rawValue,
                payloadType: Self.stateInputEdgePayloadType,
                payload: stateInput
            )

        case .stateResult(let stateResult):
            return try .init(
                id: edgeID(kind: "stateResult", order: stateResult.order),
                kind: "stateResult",
                order: stateResult.order,
                fromNodeId: stateResult.actionID.rawValue,
                toNodeId: stateResult.stateID.rawValue,
                payloadType: Self.stateResultEdgePayloadType,
                payload: stateResult
            )

        case .applied(let applied):
            return try .init(
                id: edgeID(kind: "applied", order: applied.order),
                kind: "applied",
                order: applied.order,
                fromNodeId: applied.actionID.rawValue,
                toNodeId: applied.mutationID.rawValue,
                payloadType: Self.appliedEdgePayloadType,
                payload: applied
            )

        case .startedEffect(let startedEffect):
            return try .init(
                id: edgeID(kind: "startedEffect", order: startedEffect.order),
                kind: "startedEffect",
                order: startedEffect.order,
                fromNodeId: startedEffect.actionID.rawValue,
                toNodeId: startedEffect.effectID.rawValue,
                payloadType: Self.startedEffectEdgePayloadType,
                payload: startedEffect
            )

        case .emittedAction(let emittedAction):
            return try .init(
                id: edgeID(kind: "emittedAction", order: emittedAction.order),
                kind: "emittedAction",
                order: emittedAction.order,
                fromNodeId: emittedAction.effectID.rawValue,
                toNodeId: emittedAction.nodeID,
                payloadType: Self.emittedActionEdgePayloadType,
                payload: emittedAction
            )

        case .producedAction(let producedAction):
            return try .init(
                id: edgeID(kind: "producedAction", order: producedAction.order),
                kind: "producedAction",
                order: producedAction.order,
                fromNodeId: producedAction.actionID.rawValue,
                toNodeId: producedAction.nodeID,
                payloadType: Self.producedActionEdgePayloadType,
                payload: producedAction
            )

        case .contains(let contains):
            return try .init(
                id: edgeID(kind: "contains", order: contains.order),
                kind: "contains",
                order: contains.order,
                fromNodeId: contains.batchID.rawValue,
                toNodeId: contains.nodeID,
                payloadType: Self.containsEdgePayloadType,
                payload: contains
            )

        case .nested(let nested):
            return try .init(
                id: edgeID(kind: "nested", order: nested.order),
                kind: "nested",
                order: nested.order,
                fromNodeId: nested.parentNodeID,
                toNodeId: nested.childNodeID,
                payloadType: Self.nestedEdgePayloadType,
                payload: nested
            )
        }
    }

    private static func edgeID(
        kind: String,
        order: Int
    ) -> String {
        "\(kind).\(order)"
    }

    static let dataExtension = GraphStorageCodec.compressedDataExtension
}
