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

    public init(
        title: String? = nil,
        host: String = SessionTraceLiveDefaults.defaultHost,
        port: UInt16 = SessionTraceLiveDefaults.defaultPort,
        reconnectDelay: TimeInterval = 1
    ) {
        self.title = title
        self.host = host
        self.port = port
        self.reconnectDelay = reconnectDelay
    }

    public static func sessionViewer(
        title: String? = nil,
        host: String = SessionTraceLiveDefaults.defaultHost,
        port: UInt16 = SessionTraceLiveDefaults.defaultPort
    ) -> Self {
        .init(
            title: title,
            host: host,
            port: port
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
