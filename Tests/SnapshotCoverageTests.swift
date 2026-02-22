import Foundation
import Testing
@testable import ReducerArchitecture

private enum SnapshotGapNsp: StoreNamespace {
    typealias PublishedValue = Void
    typealias StoreEnvironment = Never
    typealias EffectAction = Never

    enum MutatingAction {
        case append(Int)
    }

    struct StoreState: Equatable {
        var values: [Int] = []
    }
}

extension SnapshotGapNsp {
    @MainActor
    static func store() -> Store {
        .init(.init(), env: nil)
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .append(let value):
            state.values.append(value)
            return .none
        }
    }
}

extension SnapshotTests {
    @Suite @MainActor struct SnapshotCoverageTests {}
}

extension SnapshotTests.SnapshotCoverageTests {
    // MARK: - Persistence

    // Save collection when ReducerLogs is missing.
    // Expect save creates directory and file path.
    @Test
    func snapshotSaveCreatesReducerLogsDirectoryWhenMissing() throws {
        // Set up reducer logs backup and missing-folder state.
        let fileManager = FileManager.default
        let logsURL = try reducerLogsFolderURL()
        let backupURL = logsURL.deletingLastPathComponent()
            .appendingPathComponent("ReducerLogs_backup_\(UUID().uuidString)")
        let hadExistingLogs = fileManager.fileExists(atPath: logsURL.path)
        if hadExistingLogs {
            try fileManager.moveItem(at: logsURL, to: backupURL)
        }
        defer {
            try? fileManager.removeItem(at: logsURL)
            if hadExistingLogs {
                try? fileManager.moveItem(at: backupURL, to: logsURL)
            }
            else {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        // Trigger save with unique collection title.
        let title = "create-folder-\(UUID().uuidString)"
        let collection = ReducerSnapshotCollection(title: title, snapshots: [])
        let savedPath = try collection.save()

        // Expect folder and file created.
        #expect(savedPath != nil)
        #expect(fileManager.fileExists(atPath: logsURL.path))
        if let savedPath {
            #expect(fileManager.fileExists(atPath: savedPath))
            try? fileManager.removeItem(atPath: savedPath)
        }
    }

    // Save collection with nested title path.
    // Expect save returns nil for missing intermediate directories.
    @Test
    func snapshotSaveReturnsNilWhenPathHasMissingIntermediateDirectories() throws {
        // Set up nested-title collection.
        let title = "nested/\(UUID().uuidString)/snapshot"
        let collection = ReducerSnapshotCollection(title: title, snapshots: [])

        // Trigger save.
        let savedPath = try collection.save()

        // Expect explicit nil save result.
        #expect(savedPath == nil)
    }

    // Fail snapshot save then save again successfully.
    // Expect failed save keeps pending snapshots for retry.
    @Test
    func saveSnapshotsIfNeededKeepsPendingSnapshotsAfterFailedSave() throws {
        // Set up store with snapshot logging.
        let store = SnapshotGapNsp.store()
        let successfulTitle = "snapshot-success-\(UUID().uuidString)"
        let successfulURL = try snapshotFileURL(title: successfulTitle)
        defer { try? FileManager.default.removeItem(at: successfulURL) }
        store.logConfig.saveSnapshots = true

        // Trigger failing save, then successful save.

        store.logConfig.snapshotsFilename = "invalid/\(UUID().uuidString)/snap"
        store.send(.mutating(.append(1)))
        store.saveSnapshotsIfNeeded()

        store.logConfig.snapshotsFilename = successfulTitle
        store.send(.mutating(.append(2)))
        store.saveSnapshotsIfNeeded()

        // Expect first snapshot batch persisted on retry.
        let collection = try ReducerSnapshotCollection.load(from: successfulURL)
        #expect(collection.snapshots.count == 6)
        #expect(lastValuesStateString(in: collection) == "[1, 2]")
    }

    private func reducerLogsFolderURL() throws -> URL {
        let root = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        return root.appendingPathComponent("ReducerLogs")
    }

    private func snapshotFileURL(title: String) throws -> URL {
        try reducerLogsFolderURL()
            .appendingPathComponent("\(title)", conformingTo: .data)
            .appendingPathExtension("lzma")
    }

    private func lastValuesStateString(in collection: ReducerSnapshotCollection) -> String? {
        for snapshot in collection.snapshots.reversed() {
            switch snapshot {
            case .input(let input):
                if let value = input.state.first(where: { $0.property == "values" })?.value {
                    return value
                }
            case .stateChange(let stateChange):
                if let value = stateChange.state.first(where: { $0.property == "values" })?.value {
                    return value
                }
            case .output(let output):
                if let value = output.state.first(where: { $0.property == "values" })?.value {
                    return value
                }
            }
        }
        return nil
    }
}
