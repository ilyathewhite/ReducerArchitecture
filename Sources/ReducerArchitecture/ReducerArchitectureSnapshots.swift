//
//  ReducerArchitectureSnapshots.swift
//
//  Created by Ilya Belenkiy on 3/18/23.
//

import Foundation
import FoundationEx

public enum ReducerSnapshotData: Codable {
    public struct Input: Codable {
        public let date: Date
        public let action: String
        public let state: [CodePropertyValuePair]
        public let nestedLevel: Int

        var snapshotData: ReducerSnapshotData {
            .input(self)
        }
    }

    public struct StateChange: Codable {
        public let date: Date
        public let state: [CodePropertyValuePair]
        public let nestedLevel: Int

        var snapshotData: ReducerSnapshotData {
            .stateChange(self)
        }
    }

    public struct Output: Codable {
        public let date: Date
        public let effect: String
        public let state: [CodePropertyValuePair]
        public let nestedLevel: Int

        var snapshotData: ReducerSnapshotData {
            .output(self)
        }
    }

    case input(Input)
    case stateChange(StateChange)
    case output(Output)

    var isStateChange: Bool {
        switch self {
        case .stateChange:
            return true
        default:
            return false
        }
    }
}

public struct ReducerSnapshotCollection: Codable {
    public let title: String
    public let snapshots: [ReducerSnapshotData]

    public init(title: String, snapshots: [ReducerSnapshotData]) {
        self.title = title
        self.snapshots = snapshots
    }

    public init(compressedData: Data) throws {
        let data = try Self.decompressSnapshotData(compressedData)
        let decoder = JSONDecoder()
        self = try decoder.decode(Self.self, from: data)
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
            .appendingPathExtension(Self.snapshotDataExtension)

        let encoder = JSONEncoder()
        let data = try encoder.encode(self)
        let compressedData = try Self.compressSnapshotData(data)

        if FileManager.default.createFile(atPath: logURL.relativePath, contents: compressedData) {
            return logURL.relativePath
        }
        else {
            return nil
        }
    }

    private static func compressSnapshotData(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzma) as Data
    }

    private static func decompressSnapshotData(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzma) as Data
    }

    static let snapshotDataExtension = "lzma"
}
