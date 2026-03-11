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

extension SessionTraceTests {
    @Suite @MainActor struct SessionTraceCoverageTests {}
}

extension SessionTraceTests.SessionTraceCoverageTests {
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
        let collection = SessionTraceCollection(
            title: title,
            sessionGraph: SessionGraph(storeInstanceID: "coverage.s1", nodes: [], edges: [])
        )
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
        let collection = SessionTraceCollection(
            title: title,
            sessionGraph: SessionGraph(storeInstanceID: "coverage.s1", nodes: [], edges: [])
        )

        // Trigger save.
        let savedPath = try collection.save()

        // Expect explicit nil save result.
        #expect(savedPath == nil)
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

    private func actionNodes(in collection: SessionTraceCollection) -> [SessionGraph.ActionNode] {
        collection.sessionGraph.nodes.compactMap { node -> SessionGraph.ActionNode? in
            guard case .action(let actionNode) = node else { return nil }
            return actionNode
        }
        .sorted(by: { $0.order < $1.order })
    }

    private func lastValuesStateString(in collection: SessionTraceCollection) -> String? {
        for actionNode in actionNodes(in: collection).reversed() {
            if let value = actionNode.stateAfter?.first(where: { $0.property == "values" })?.value {
                return value
            }
            if let value = actionNode.stateBefore.first(where: { $0.property == "values" })?.value {
                return value
            }
        }
        return nil
    }
}
