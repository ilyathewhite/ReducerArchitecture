//  LiveTrace.swift

#if DEBUG
//  Created by Ilya Belenkiy on 3/3/26.

import Foundation

private func normalizedLiveTraceValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func liveTraceStoreTypeName(from storeInstanceID: String) -> String {
    if let suffixRange = storeInstanceID.range(of: ".s", options: .backwards) {
        let suffix = storeInstanceID[suffixRange.upperBound...]
        if !suffix.isEmpty && suffix.allSatisfy(\.isNumber) {
            return String(storeInstanceID[..<suffixRange.lowerBound])
        }
    }
    return storeInstanceID
}

private func liveTraceShortStoreTypeName(from storeInstanceID: String) -> String {
    let storeTypeName = liveTraceStoreTypeName(from: storeInstanceID)
    return storeTypeName.split(separator: ".").last.map(String.init) ?? storeTypeName
}

private func liveTraceStoreNameLooksDefault(
    _ storeName: String?,
    storeInstanceID: String
) -> Bool {
    guard let normalizedStoreName = normalizedLiveTraceValue(storeName) else { return true }
    let storeTypeName = liveTraceStoreTypeName(from: storeInstanceID)
    let shortStoreTypeName = liveTraceShortStoreTypeName(from: storeInstanceID)
    return normalizedStoreName == storeTypeName || normalizedStoreName == shortStoreTypeName
}

public enum LiveTraceDefaults {
    public static let defaultHost = "127.0.0.1"
    public static let defaultPort: UInt16 = 38765
}

public struct LiveTraceConfig: Sendable {
    public var sessionTitle: String?
    public var sessionID: String?
    public var networkEnabled: Bool
    public var host: String
    public var port: UInt16
    public var patchBufferCapacity: Int
    public var envelopeHandler: (@Sendable (LiveTraceEnvelope) -> Void)?
    /// When enabled, every newly created `StateStore` automatically joins live tracing with
    /// `.selfAndChildren`, which also preserves parent/child store relationships.
    public var traceAllStores: Bool

    /// Shared per-process configuration for one app-run live-trace session.
    ///
    /// Configure this once before any traced store starts recording, then either opt stores into
    /// the shared session with `store.logConfig.liveTraceEnabled` or set `traceAllStores = true`
    /// to trace all stores created afterwards.
    ///
    /// By default, traced stores stream to the SessionTraceViewer TCP listener. Tests and tools
    /// can disable network recording and install an in-process `envelopeHandler` instead.
    @MainActor
    public static var shared = Self()

    public init(
        sessionTitle: String? = nil,
        sessionID: String? = nil,
        networkEnabled: Bool = true,
        host: String = LiveTraceDefaults.defaultHost,
        port: UInt16 = LiveTraceDefaults.defaultPort,
        patchBufferCapacity: Int = 256,
        envelopeHandler: (@Sendable (LiveTraceEnvelope) -> Void)? = nil,
        traceAllStores: Bool = false
    ) {
        self.sessionTitle = sessionTitle
        self.sessionID = sessionID
        self.networkEnabled = networkEnabled
        self.host = host
        self.port = port
        self.patchBufferCapacity = max(1, patchBufferCapacity)
        self.envelopeHandler = envelopeHandler
        self.traceAllStores = traceAllStores
    }
}

extension LiveTraceConfig {
    var hasOutputs: Bool {
        networkEnabled || envelopeHandler != nil
    }
}

public struct TraceSession: Codable, Equatable, Identifiable, Sendable {
    public struct StoreTrace: Codable, Equatable, Identifiable, Sendable {
        public let storeInstanceID: String
        public let storeName: String?
        public let parentStoreInstanceID: String?
        public let childKeyInParentStore: String?
        public let hostName: String?
        public let processName: String?
        public let startedAt: Date?
        public let endedAt: Date?
        public let traceCollection: SessionTraceCollection

        public init(
            storeInstanceID: String,
            storeName: String?,
            parentStoreInstanceID: String? = nil,
            childKeyInParentStore: String? = nil,
            hostName: String?,
            processName: String?,
            startedAt: Date?,
            endedAt: Date? = nil,
            traceCollection: SessionTraceCollection
        ) {
            self.storeInstanceID = storeInstanceID
            self.storeName = storeName
            self.parentStoreInstanceID = parentStoreInstanceID
            self.childKeyInParentStore = childKeyInParentStore
            self.hostName = hostName
            self.processName = processName
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.traceCollection = traceCollection
        }

        public var id: String {
            storeInstanceID
        }

        public var displayName: String {
            if let storeName = normalizedLiveTraceValue(storeName) {
                return storeName
            }
            if let title = normalizedLiveTraceValue(traceCollection.title) {
                return title
            }
            return storeInstanceID
        }

        public var isEnded: Bool {
            endedAt != nil
        }
    }

    public let sessionID: String
    public let title: String
    public let hostName: String?
    public let processName: String?
    public let startedAt: Date?
    public let storeTraces: [StoreTrace]

    public init(
        sessionID: String,
        title: String,
        hostName: String?,
        processName: String?,
        startedAt: Date?,
        storeTraces: [StoreTrace]
    ) {
        self.sessionID = sessionID
        self.title = title
        self.hostName = hostName
        self.processName = processName
        self.startedAt = startedAt
        self.storeTraces = storeTraces
    }

    public init(fileData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: fileData)
    }

    public var id: String {
        sessionID
    }

    public var firstStoreTrace: StoreTrace? {
        storeTraces.first
    }

    public func storeTrace(id: String?) -> StoreTrace? {
        guard let id else { return firstStoreTrace }
        return storeTraces.first(where: { $0.id == id }) ?? firstStoreTrace
    }
}

public struct LiveTraceStoreMetadata: Codable, Equatable, Sendable {
    public let sessionID: String
    public let storeInstanceID: String
    public let title: String
    public let storeName: String
    public let parentStoreInstanceID: String?
    public let childKeyInParentStore: String?
    public let hostName: String
    public let processName: String
    public let startedAt: Date
    public let endedAt: Date?

    public init(
        sessionID: String,
        storeInstanceID: String,
        title: String,
        storeName: String,
        parentStoreInstanceID: String? = nil,
        childKeyInParentStore: String? = nil,
        hostName: String,
        processName: String,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.sessionID = sessionID
        self.storeInstanceID = storeInstanceID
        self.title = title
        self.storeName = storeName
        self.parentStoreInstanceID = parentStoreInstanceID
        self.childKeyInParentStore = childKeyInParentStore
        self.hostName = hostName
        self.processName = processName
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public var isEnded: Bool {
        endedAt != nil
    }

    public func ended(at date: Date = .now) -> Self {
        .init(
            sessionID: sessionID,
            storeInstanceID: storeInstanceID,
            title: title,
            storeName: storeName,
            parentStoreInstanceID: parentStoreInstanceID,
            childKeyInParentStore: childKeyInParentStore,
            hostName: hostName,
            processName: processName,
            startedAt: startedAt,
            endedAt: date
        )
    }
}

public enum LiveTracePatch: Codable, Equatable, Sendable {
    case upsertNode(SessionGraph.Node)
    case appendEdge(SessionGraph.Edge)
}

public enum LiveTraceMessageKind: String, Codable, Sendable {
    case hello
    case snapshot
    case patch
}

public struct LiveTraceEnvelope: Codable, Equatable, Sendable {
    public let sessionID: String
    public let storeInstanceID: String
    public let kind: LiveTraceMessageKind
    public let metadata: LiveTraceStoreMetadata?
    public let traceCollection: SessionTraceCollection?
    public let patch: LiveTracePatch?

    public init(
        sessionID: String,
        storeInstanceID: String,
        kind: LiveTraceMessageKind,
        metadata: LiveTraceStoreMetadata? = nil,
        traceCollection: SessionTraceCollection? = nil,
        patch: LiveTracePatch? = nil
    ) {
        self.sessionID = sessionID
        self.storeInstanceID = storeInstanceID
        self.kind = kind
        self.metadata = metadata
        self.traceCollection = traceCollection
        self.patch = patch
    }

    public static func hello(_ metadata: LiveTraceStoreMetadata) -> Self {
        .init(
            sessionID: metadata.sessionID,
            storeInstanceID: metadata.storeInstanceID,
            kind: .hello,
            metadata: metadata
        )
    }

    public static func snapshot(
        sessionID: String,
        storeInstanceID: String,
        traceCollection: SessionTraceCollection
    ) -> Self {
        .init(
            sessionID: sessionID,
            storeInstanceID: storeInstanceID,
            kind: .snapshot,
            traceCollection: traceCollection
        )
    }

    public static func patch(
        sessionID: String,
        storeInstanceID: String,
        patch: LiveTracePatch
    ) -> Self {
        .init(
            sessionID: sessionID,
            storeInstanceID: storeInstanceID,
            kind: .patch,
            patch: patch
        )
    }

}

public struct LiveTraceStoreAccumulator: Sendable {
    public var title: String

    private let storeInstanceID: SessionGraph.StoreInstanceID
    private var schemaVersion: Int
    private var nodesByID: [String: SessionGraph.Node]
    private var edges: [SessionGraph.Edge]

    public init(
        title: String,
        storeInstanceID: String
    ) {
        self.title = title
        self.storeInstanceID = .init(rawValue: storeInstanceID)
        self.schemaVersion = SessionGraph.currentSchemaVersion
        self.nodesByID = [:]
        self.edges = []
    }

    public mutating func apply(metadata: LiveTraceStoreMetadata) {
        guard metadata.storeInstanceID == storeInstanceID.rawValue else { return }
        title = metadata.storeName
    }

    public mutating func replace(with traceCollection: SessionTraceCollection) {
        guard traceCollection.sessionGraph.storeInstanceID == storeInstanceID else { return }

        if normalizedLiveTraceValue(title) == nil || title == storeInstanceID.rawValue {
            title = traceCollection.title
        }
        schemaVersion = traceCollection.sessionGraph.schemaVersion
        nodesByID = Dictionary(
            uniqueKeysWithValues: traceCollection.sessionGraph.nodes.map { ($0.id, $0) }
        )
        edges = traceCollection.sessionGraph.edges.sorted(by: Self.edgeSort)
    }

    public mutating func apply(_ patch: LiveTracePatch) {
        switch patch {
        case .upsertNode(let node):
            nodesByID[node.id] = node

        case .appendEdge(let edge):
            edges.append(edge)
        }
    }

    public mutating func apply(_ envelope: LiveTraceEnvelope) {
        guard envelope.storeInstanceID == storeInstanceID.rawValue else { return }

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

public struct LiveTraceSessionAccumulator: Sendable {
    private struct StoreAccumulator: Sendable {
        var metadata: LiveTraceStoreMetadata?
        var traceAccumulator: LiveTraceStoreAccumulator
        var lastUpdatedAt: Date

        init(
            storeInstanceID: String,
            title: String
        ) {
            self.metadata = nil
            self.traceAccumulator = .init(
                title: title,
                storeInstanceID: storeInstanceID
            )
            self.lastUpdatedAt = .now
        }
    }

    public var title: String
    public private(set) var startedAt: Date?
    public private(set) var hostName: String?
    public private(set) var processName: String?
    public private(set) var lastUpdatedAt: Date

    private let sessionID: String
    private var storeOrder: [String]
    private var storesByID: [String: StoreAccumulator]
    private var autoNameByStoreID: [String: String]
    private var autoNameCountByStoreType: [String: Int]

    public init(
        title: String,
        sessionID: String
    ) {
        self.title = title
        self.startedAt = nil
        self.hostName = nil
        self.processName = nil
        self.lastUpdatedAt = .now
        self.sessionID = sessionID
        self.storeOrder = []
        self.storesByID = [:]
        self.autoNameByStoreID = [:]
        self.autoNameCountByStoreType = [:]
    }

    public mutating func apply(metadata: LiveTraceStoreMetadata) {
        guard metadata.sessionID == sessionID else { return }

        let metadata = resolvedMetadata(metadata)

        title = metadata.title
        startedAt = startedAt.map { min($0, metadata.startedAt) } ?? metadata.startedAt
        hostName = normalizedLiveTraceValue(hostName) ?? normalizedLiveTraceValue(metadata.hostName)
        processName = normalizedLiveTraceValue(processName) ?? normalizedLiveTraceValue(metadata.processName)

        var store = storeAccumulator(
            for: metadata.storeInstanceID,
            fallbackTitle: metadata.storeName
        )
        store.metadata = metadata
        store.traceAccumulator.apply(metadata: metadata)
        store.lastUpdatedAt = .now
        storesByID[metadata.storeInstanceID] = store
        lastUpdatedAt = store.lastUpdatedAt
    }

    public mutating func apply(_ envelope: LiveTraceEnvelope) {
        guard envelope.sessionID == sessionID else { return }

        switch envelope.kind {
        case .hello:
            if let metadata = envelope.metadata {
                apply(metadata: metadata)
            }

        case .snapshot:
            var store = storeAccumulator(
                for: envelope.storeInstanceID,
                fallbackTitle: envelope.storeInstanceID
            )
            if let traceCollection = envelope.traceCollection {
                store.traceAccumulator.replace(with: traceCollection)
                if let metadata = store.metadata {
                    store.traceAccumulator.apply(metadata: metadata)
                }
            }
            store.lastUpdatedAt = .now
            storesByID[envelope.storeInstanceID] = store
            lastUpdatedAt = store.lastUpdatedAt

        case .patch:
            var store = storeAccumulator(
                for: envelope.storeInstanceID,
                fallbackTitle: envelope.storeInstanceID
            )
            if let patch = envelope.patch {
                store.traceAccumulator.apply(patch)
            }
            store.lastUpdatedAt = .now
            storesByID[envelope.storeInstanceID] = store
            lastUpdatedAt = store.lastUpdatedAt
        }
    }

    public var session: TraceSession {
        let sessionHostName = hostName
        let sessionProcessName = processName
        return .init(
            sessionID: sessionID,
            title: title,
            hostName: sessionHostName,
            processName: sessionProcessName,
            startedAt: startedAt,
            storeTraces: storeOrder.compactMap { storeInstanceID in
                guard let store = storesByID[storeInstanceID] else { return nil }
                let metadata = store.metadata
                return .init(
                    storeInstanceID: storeInstanceID,
                    storeName: metadata?.storeName,
                    parentStoreInstanceID: metadata?.parentStoreInstanceID,
                    childKeyInParentStore: metadata?.childKeyInParentStore,
                    hostName: metadata.flatMap { normalizedLiveTraceValue($0.hostName) } ?? sessionHostName,
                    processName: metadata.flatMap { normalizedLiveTraceValue($0.processName) } ?? sessionProcessName,
                    startedAt: metadata?.startedAt,
                    endedAt: metadata?.endedAt,
                    traceCollection: store.traceAccumulator.traceCollection
                )
            }
        )
    }

    private mutating func storeAccumulator(
        for storeInstanceID: String,
        fallbackTitle: String
    ) -> StoreAccumulator {
        if let store = storesByID[storeInstanceID] {
            return store
        }
        storeOrder.append(storeInstanceID)
        return .init(
            storeInstanceID: storeInstanceID,
            title: fallbackTitle
        )
    }

    private mutating func resolvedMetadata(_ metadata: LiveTraceStoreMetadata) -> LiveTraceStoreMetadata {
        guard liveTraceStoreNameLooksDefault(metadata.storeName, storeInstanceID: metadata.storeInstanceID) else {
            return metadata
        }

        let shortStoreTypeName = liveTraceShortStoreTypeName(from: metadata.storeInstanceID)
        let resolvedStoreName: String
        if let existingName = autoNameByStoreID[metadata.storeInstanceID] {
            resolvedStoreName = existingName
        }
        else {
            let nextIndex = (autoNameCountByStoreType[shortStoreTypeName] ?? 0) + 1
            autoNameCountByStoreType[shortStoreTypeName] = nextIndex
            resolvedStoreName =
                if nextIndex == 1 {
                    shortStoreTypeName
                }
                else {
                    "\(shortStoreTypeName) \(nextIndex)"
                }
            autoNameByStoreID[metadata.storeInstanceID] = resolvedStoreName
        }

        return .init(
            sessionID: metadata.sessionID,
            storeInstanceID: metadata.storeInstanceID,
            title: metadata.title,
            storeName: resolvedStoreName,
            parentStoreInstanceID: metadata.parentStoreInstanceID,
            childKeyInParentStore: metadata.childKeyInParentStore,
            hostName: metadata.hostName,
            processName: metadata.processName,
            startedAt: metadata.startedAt,
            endedAt: metadata.endedAt
        )
    }
}

enum LiveTraceCodec {
    static func encode(_ envelope: LiveTraceEnvelope) throws -> Data {
        var encoded = try JSONEncoder().encode(envelope)
        encoded.append(0x0A)
        return encoded
    }

    static func decode(_ data: Data) throws -> LiveTraceEnvelope {
        try JSONDecoder().decode(LiveTraceEnvelope.self, from: data)
    }
}
#endif
