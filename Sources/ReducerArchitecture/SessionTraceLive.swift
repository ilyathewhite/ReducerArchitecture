//  SessionTraceLive.swift
//  Created by Ilya Belenkiy on 3/3/26.

import Foundation

public enum SessionTraceLiveDefaults {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 38765
}

public struct SessionTraceLiveConfig: Sendable {
    public var title: String?
    public var host: String
    public var port: UInt16
    public var reconnectDelay: TimeInterval
    public var patchBufferCapacity: Int

    public init(
        title: String? = nil,
        host: String = SessionTraceLiveDefaults.defaultHost,
        port: UInt16 = SessionTraceLiveDefaults.defaultPort,
        reconnectDelay: TimeInterval = 1,
        patchBufferCapacity: Int = 256
    ) {
        self.title = title
        self.host = host
        self.port = port
        self.reconnectDelay = reconnectDelay
        self.patchBufferCapacity = max(1, patchBufferCapacity)
    }

    public static func sessionViewer(
        title: String? = nil,
        host: String = SessionTraceLiveDefaults.defaultHost,
        port: UInt16 = SessionTraceLiveDefaults.defaultPort,
        patchBufferCapacity: Int = 256
    ) -> Self {
        .init(
            title: title,
            host: host,
            port: port,
            patchBufferCapacity: patchBufferCapacity
        )
    }
}

public struct SessionTraceLiveSessionMetadata: Codable, Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let storeName: String
    public let hostName: String
    public let processName: String
    public let startedAt: Date

    public init(
        sessionID: String,
        title: String,
        storeName: String,
        hostName: String,
        processName: String,
        startedAt: Date
    ) {
        self.sessionID = sessionID
        self.title = title
        self.storeName = storeName
        self.hostName = hostName
        self.processName = processName
        self.startedAt = startedAt
    }
}

public enum SessionTraceLivePatch: Codable, Equatable, @unchecked Sendable {
    case upsertNode(SessionGraph.Node)
    case appendEdge(SessionGraph.Edge)
}

public enum SessionTraceLiveMessageKind: String, Codable, Sendable {
    case hello
    case snapshot
    case patch
    case end
}

public struct SessionTraceLiveEnvelope: Codable, @unchecked Sendable {
    public let sessionID: String
    public let kind: SessionTraceLiveMessageKind
    public let metadata: SessionTraceLiveSessionMetadata?
    public let traceCollection: SessionTraceCollection?
    public let patch: SessionTraceLivePatch?

    public init(
        sessionID: String,
        kind: SessionTraceLiveMessageKind,
        metadata: SessionTraceLiveSessionMetadata? = nil,
        traceCollection: SessionTraceCollection? = nil,
        patch: SessionTraceLivePatch? = nil
    ) {
        self.sessionID = sessionID
        self.kind = kind
        self.metadata = metadata
        self.traceCollection = traceCollection
        self.patch = patch
    }

    public static func hello(_ metadata: SessionTraceLiveSessionMetadata) -> Self {
        .init(
            sessionID: metadata.sessionID,
            kind: .hello,
            metadata: metadata
        )
    }

    public static func snapshot(
        sessionID: String,
        traceCollection: SessionTraceCollection
    ) -> Self {
        .init(
            sessionID: sessionID,
            kind: .snapshot,
            traceCollection: traceCollection
        )
    }

    public static func patch(
        sessionID: String,
        patch: SessionTraceLivePatch
    ) -> Self {
        .init(
            sessionID: sessionID,
            kind: .patch,
            patch: patch
        )
    }

    public static func end(sessionID: String) -> Self {
        .init(
            sessionID: sessionID,
            kind: .end
        )
    }
}

public struct SessionTraceLiveAccumulator: @unchecked Sendable {
    public var title: String

    private let sessionID: String
    private var schemaVersion: Int
    private var storeInstanceID: SessionGraph.StoreInstanceID
    private var nodesByID: [String: SessionGraph.Node]
    private var edges: [SessionGraph.Edge]

    public init(
        title: String,
        sessionID: String
    ) {
        self.title = title
        self.sessionID = sessionID
        self.schemaVersion = SessionGraph.currentSchemaVersion
        self.storeInstanceID = .init(rawValue: sessionID)
        self.nodesByID = [:]
        self.edges = []
    }

    public mutating func apply(metadata: SessionTraceLiveSessionMetadata) {
        guard metadata.sessionID == sessionID else { return }
        title = metadata.title
    }

    public mutating func replace(with traceCollection: SessionTraceCollection) {
        title = traceCollection.title
        schemaVersion = traceCollection.sessionGraph.schemaVersion
        storeInstanceID = traceCollection.sessionGraph.storeInstanceID
        nodesByID = Dictionary(
            uniqueKeysWithValues: traceCollection.sessionGraph.nodes.map { ($0.id, $0) }
        )
        edges = traceCollection.sessionGraph.edges.sorted(by: Self.edgeSort)
    }

    public mutating func apply(_ patch: SessionTraceLivePatch) {
        switch patch {
        case .upsertNode(let node):
            nodesByID[node.id] = node

        case .appendEdge(let edge):
            edges.append(edge)
        }
    }

    public mutating func apply(_ envelope: SessionTraceLiveEnvelope) {
        guard envelope.sessionID == sessionID else { return }

        switch envelope.kind {
        case .hello:
            if let metadata = envelope.metadata {
                apply(metadata: metadata)
            }

        case .snapshot:
            if let traceCollection = envelope.traceCollection {
                replace(with: traceCollection)
            }

        case .patch:
            if let patch = envelope.patch {
                apply(patch)
            }

        case .end:
            break
        }
    }

    public var traceCollection: SessionTraceCollection {
        .init(
            title: title,
            sessionGraph: .init(
                schemaVersion: schemaVersion,
                storeInstanceID: storeInstanceID,
                nodes: nodesByID.values.sorted(by: Self.nodeSort),
                edges: edges.sorted(by: Self.edgeSort)
            )
        )
    }

    private static func nodeSort(lhs: SessionGraph.Node, rhs: SessionGraph.Node) -> Bool {
        if lhs.order == rhs.order {
            return lhs.id < rhs.id
        }
        return lhs.order < rhs.order
    }

    private static func edgeSort(lhs: SessionGraph.Edge, rhs: SessionGraph.Edge) -> Bool {
        lhs.order < rhs.order
    }
}

enum SessionTraceLiveCodec {
    static func encode(_ envelope: SessionTraceLiveEnvelope) throws -> Data {
        var encoded = try JSONEncoder().encode(envelope)
        encoded.append(0x0A)
        return encoded
    }

    static func decode(_ data: Data) throws -> SessionTraceLiveEnvelope {
        try JSONDecoder().decode(SessionTraceLiveEnvelope.self, from: data)
    }
}
