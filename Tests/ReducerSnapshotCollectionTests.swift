import Foundation
import Testing
@testable import ReducerArchitecture

extension SnapshotTests {
    @Suite struct ReducerSnapshotCollectionTests {}
}

extension SnapshotTests.ReducerSnapshotCollectionTests {
    // MARK: - Persistence

    // Save and reload snapshots.
    // Expect round-trip preserves payload.
    @Test
    func saveAndLoadRoundTripsSnapshotData() throws {
        // Set up snapshot collection.
        let title = "snapshot-test-\(UUID().uuidString)"
        let startDate = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshots: [ReducerSnapshotData] = [
            .input(.init(date: startDate, action: "mutating.update", state: [], nestedLevel: 0)),
            .stateChange(.init(date: startDate.addingTimeInterval(1), state: [], nestedLevel: 1)),
            .output(.init(date: startDate.addingTimeInterval(2), effect: "none", state: [], nestedLevel: 2))
        ]
        let collection = ReducerSnapshotCollection(title: title, snapshots: snapshots)

        // Trigger save and reload.
        guard let path = try collection.save() else {
            #expect(Bool(false))
            return
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let loaded = try ReducerSnapshotCollection.load(from: URL(fileURLWithPath: path))

        // Expect round-trip values.
        #expect(loaded.title == title)
        #expect(loaded.snapshots.count == 3)

        guard let input = inputData(from: loaded.snapshots[0]) else {
            #expect(Bool(false))
            return
        }
        #expect(input.action == "mutating.update")
        #expect(input.nestedLevel == 0)

        guard let stateChange = stateChangeData(from: loaded.snapshots[1]) else {
            #expect(Bool(false))
            return
        }
        #expect(stateChange.nestedLevel == 1)

        guard let output = outputData(from: loaded.snapshots[2]) else {
            #expect(Bool(false))
            return
        }
        #expect(output.effect == "none")
        #expect(output.nestedLevel == 2)
    }

    // Map mixed snapshots to state-change flags.
    // Expect only state-change case returns true.
    @Test
    func isStateChangeFlagsOnlyStateChangeCase() {
        // Set up mixed snapshot values.
        let snapshots: [ReducerSnapshotData] = [
            .input(.init(date: .now, action: "a", state: [], nestedLevel: 0)),
            .stateChange(.init(date: .now, state: [], nestedLevel: 0)),
            .output(.init(date: .now, effect: "e", state: [], nestedLevel: 0))
        ]

        // Trigger mapping.
        let flags = snapshots.map(\.isStateChange)

        // Expect state-change-only truthy flag.
        #expect(flags == [false, true, false])
    }

    // Initialize from invalid compressed bytes.
    // Expect throw.
    @Test
    func initWithInvalidCompressedDataThrows() {
        // Set up invalid payload.
        let invalidCompressedData = Data("not-a-snapshot".utf8)

        // Trigger and expect thrown error.
        #expect(throws: (any Error).self) {
            try ReducerSnapshotCollection(compressedData: invalidCompressedData)
        }
    }

    private func inputData(from snapshot: ReducerSnapshotData) -> ReducerSnapshotData.Input? {
        guard case .input(let input) = snapshot else {
            return nil
        }
        return input
    }

    private func stateChangeData(from snapshot: ReducerSnapshotData) -> ReducerSnapshotData.StateChange? {
        guard case .stateChange(let stateChange) = snapshot else {
            return nil
        }
        return stateChange
    }

    private func outputData(from snapshot: ReducerSnapshotData) -> ReducerSnapshotData.Output? {
        guard case .output(let output) = snapshot else {
            return nil
        }
        return output
    }
}
