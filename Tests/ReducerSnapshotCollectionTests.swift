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
        let path = try #require(try collection.save())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let loaded = try ReducerSnapshotCollection.load(from: URL(fileURLWithPath: path))

        // Expect round-trip values.
        #expect(loaded.title == title)
        #expect(loaded.snapshots.count == 3)

        let inputIsInput: Bool
        let inputAction: String?
        let inputNestedLevel: Int?
        switch loaded.snapshots[0] {
        case .input(let input):
            inputIsInput = true
            inputAction = input.action
            inputNestedLevel = input.nestedLevel
        default:
            inputIsInput = false
            inputAction = nil
            inputNestedLevel = nil
        }
        #expect(inputIsInput)
        #expect(inputAction == "mutating.update")
        #expect(inputNestedLevel == 0)

        let stateChangeIsStateChange: Bool
        let stateChangeNestedLevel: Int?
        switch loaded.snapshots[1] {
        case .stateChange(let stateChange):
            stateChangeIsStateChange = true
            stateChangeNestedLevel = stateChange.nestedLevel
        default:
            stateChangeIsStateChange = false
            stateChangeNestedLevel = nil
        }
        #expect(stateChangeIsStateChange)
        #expect(stateChangeNestedLevel == 1)

        let outputIsOutput: Bool
        let outputEffect: String?
        let outputNestedLevel: Int?
        switch loaded.snapshots[2] {
        case .output(let output):
            outputIsOutput = true
            outputEffect = output.effect
            outputNestedLevel = output.nestedLevel
        default:
            outputIsOutput = false
            outputEffect = nil
            outputNestedLevel = nil
        }
        #expect(outputIsOutput)
        #expect(outputEffect == "none")
        #expect(outputNestedLevel == 2)
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

}
