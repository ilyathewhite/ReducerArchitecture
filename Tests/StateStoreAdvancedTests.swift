import Combine
import Foundation
import Testing
@testable import ReducerArchitecture

private enum EffectHarnessNsp: StoreNamespace {
    typealias PublishedValue = String

    struct StoreEnvironment {
        var publisher: AnyPublisher<Store.Action, Never>
    }

    enum MutatingAction {
        case append(Int)
        case setMarker(String)
        case emitSyncFollowUps
    }

    enum EffectAction {
        case emitAction(Int)
        case emitActions([Int])
        case emitAsync(Int)
        case emitAsyncLatest(value: Int, delay: TimeInterval)
        case emitAsyncActions([Int])
        case emitSequence([Int])
        case subscribeToPublisher
        case emitPublish(String)
    }

    struct StoreState: Equatable {
        var values: [Int] = []
        var marker = ""
    }
}

extension EffectHarnessNsp {
    @MainActor
    static func store(
        publisher: AnyPublisher<Store.Action, Never> = Empty<Store.Action, Never>(completeImmediately: false).eraseToAnyPublisher()
    ) -> Store {
        .init(.init(), env: .init(publisher: publisher))
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .append(let value):
            state.values.append(value)
            return .none

        case .setMarker(let value):
            state.marker = value
            return .none

        case .emitSyncFollowUps:
            return .actions([.mutating(.append(7)), .mutating(.append(8))])
        }
    }

    static func runEffect(_ env: StoreEnvironment, _ state: StoreState, _ action: EffectAction) -> Store.Effect {
        switch action {
        case .emitAction(let value):
            return .action(.mutating(.append(value)))

        case .emitActions(let values):
            return .actions(values.map { .mutating(.append($0)) })

        case .emitAsync(let value):
            return .asyncAction {
                .mutating(.append(value))
            }

        case .emitAsyncLatest(let value, let delay):
            return .asyncActionLatest(key: "latest") {
                try? await Task.sleep(for: .seconds(delay))
                return .mutating(.append(value))
            }

        case .emitAsyncActions(let values):
            return .asyncActions {
                values.map { .mutating(.append($0)) }
            }

        case .emitSequence(let values):
            return .asyncActionSequence { send in
                for value in values {
                    send(.mutating(.append(value)))
                    await Task.yield()
                }
            }

        case .subscribeToPublisher:
            return .publisher(env.publisher)

        case .emitPublish(let value):
            return .action(.publish(value))
        }
    }
}

private enum PublishedIntSourceNsp: StoreNamespace {
    typealias PublishedValue = Int
    typealias StoreEnvironment = Never
    typealias EffectAction = Never

    enum MutatingAction {
        case set(Int)
    }

    struct StoreState: Equatable {
        var value = 0
    }
}

extension PublishedIntSourceNsp {
    @MainActor
    static func store() -> Store {
        .init(.init(), env: nil)
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .set(let value):
            state.value = value
            return .none
        }
    }
}

extension StateStoreTests {
    @Suite @MainActor struct StateStoreAdvancedTests {}
}

extension StateStoreTests.StateStoreAdvancedTests {
    // MARK: - Effects

    // Emit reducer follow-up actions.
    // Expect sync follow-ups apply in order.
    @Test
    func reducerSyncEffectRunsFollowUpActions() {
        // Set up store.
        let store = EffectHarnessNsp.store()

        // Trigger sync follow-up emission.
        store.send(.mutating(.emitSyncFollowUps))

        // Expect ordered values.
        #expect(store.state.values == [7, 8])
    }

    // Emit immediate action effect.
    // Expect value is appended.
    @Test
    func effectActionRunsImmediateAction() async {
        // Set up store.
        let store = EffectHarnessNsp.store()

        // Trigger immediate effect action.
        _ = store.send(.effect(.emitAction(3)))
        await Task.yield()

        // Expect single appended value.
        #expect(store.state.values == [3])
    }

    // Emit multi-action effect.
    // Expect all values are appended.
    @Test
    func effectActionRunsMultipleActions() async {
        // Set up store.
        let store = EffectHarnessNsp.store()

        // Trigger grouped effect actions.
        _ = store.send(.effect(.emitActions([1, 2, 3])))
        await Task.yield()

        // Expect all grouped values.
        #expect(store.state.values == [1, 2, 3])
    }

    // Emit async action effect.
    // Expect awaited action appends value.
    @Test
    func effectActionRunsAsyncAction() async {
        // Set up store.
        let store = EffectHarnessNsp.store()

        // Trigger and await async action.
        let task = store.send(.effect(.emitAsync(9)))
        await task?.value

        // Expect appended async value.
        #expect(store.state.values == [9])
    }

    // Start two async-latest effects.
    // Expect only latest result applies.
    @Test
    func effectActionRunsAsyncLatestOnlyOnce() async {
        // Set up store.
        let store = EffectHarnessNsp.store()

        // Trigger competing async-latest effects.
        let first = store.send(.effect(.emitAsyncLatest(value: 1, delay: 0.15)))
        let second = store.send(.effect(.emitAsyncLatest(value: 2, delay: 0.02)))
        await first?.value
        await second?.value

        // Expect latest value only.
        #expect(store.state.values == [2])
    }

    // Emit async actions effect.
    // Expect all async results append.
    @Test
    func effectActionRunsAsyncActions() async {
        // Set up store.
        let store = EffectHarnessNsp.store()

        // Trigger and await async actions.
        let task = store.send(.effect(.emitAsyncActions([4, 5, 6])))
        await task?.value

        // Expect all async values.
        #expect(store.state.values == [4, 5, 6])
    }

    // Emit async action sequence.
    // Expect setup completes before delayed sequence drains.
    @Test
    func effectActionSequenceForwardsValuesAfterSetupCompletes() async {
        // Set up store.
        let store = EffectHarnessNsp.store()

        // Trigger and await sequence.
        let task = store.send(.effect(.emitSequence([10, 11, 12])))
        await task?.value
        try? await Task.sleep(for: .seconds(0.05))

        // Expect all sequence values.
        #expect(store.state.values == [10, 11, 12])
    }

    // Subscribe store to publisher effect.
    // Expect values stop after cancellation.
    @Test
    func publisherEffectStopsAfterStoreCancel() async {
        // Set up replaying publisher and store.
        let subject = CurrentValueSubject<EffectHarnessNsp.Store.Action, Never>(.mutating(.append(1)))
        let store = EffectHarnessNsp.store(publisher: subject.eraseToAnyPublisher())

        // Start long-lived publisher effect.
        let effectTask = Task { @MainActor in
            _ = store.send(.effect(.subscribeToPublisher))
        }

        // Observe first value, then cancel and emit one more value.
        let assertionTask = Task { @MainActor in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var cancellable: AnyCancellable?
                cancellable = store.distinctValues(on: \.values).sink { values in
                    guard values == [1] else { return }
                    cancellable?.cancel()
                    continuation.resume()
                }
            }
            store.cancel()
            await Task.yield()
            subject.send(.mutating(.append(2)))
            await Task.yield()
        }

        _ = await effectTask.value
        await assertionTask.value

        // Expect only pre-cancel value.
        #expect(store.state.values == [1])
        #expect(store.isCancelled)
    }

    // MARK: - Binding

    // Bind published source value to target.
    // Expect first published value forwards.
    @Test
    func bindPublishedValueForwardsSourceValues() async {
        // Set up source and target stores.
        let source = PublishedIntSourceNsp.store()
        let target = EffectHarnessNsp.store()

        // Start long-lived binding effect.
        let bindTask = Task { @MainActor in
            await target.bindPublishedValue(of: source, with: { .mutating(.append($0)) })?.value
            target.cancel()
        }

        // Wait until source.value is subscribed to so publish/cancel are not missed.
        await source.getRequest()

        // Emit one value, then close the source to finish the bind task.
        source.publish(21)
        source.cancel()

        // Capture the initial state and the forwarded state update from target.
        var targetValues = [[Int]]()
        for await values in target.asyncValues(on: \.values) {
            if !source.isCancelled { break }
            targetValues.append(values)
        }
        #expect(targetValues == [[], [21]])

        await bindTask.value
    }

    // Cancel source store after binding.
    // Expect target is also cancelled.
    @Test
    func bindPublishedValueCancelsTargetOnSourceCancel() async {
        // Set up source and target stores.
        let source = PublishedIntSourceNsp.store()
        let target = EffectHarnessNsp.store()

        // Start long-lived binding effect.
        let bindTask = Task { @MainActor in
            await target.bindPublishedValue(of: source, with: { .mutating(.append($0)) })?.value
        }

        // Cancel source after binding subscription is active.
        await source.getRequest()
        source.cancel()
        await bindTask.value

        // Expect cancellation propagation.
        #expect(target.isCancelled)
    }
}

extension SnapshotTests {
    @Suite @MainActor struct StateStoreSnapshotPersistenceTests {}
}

extension SnapshotTests.StateStoreSnapshotPersistenceTests {
    // Save snapshots after mutations.
    // Expect latest state is persisted.
    @Test
    func saveSnapshotsIfNeededWritesLatestActionState() throws {
        // Set up snapshot file and store logging.
        let title = "store-snapshots-\(UUID().uuidString)"
        let fileURL = try stateStoreSnapshotFileURL(title: title)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = EffectHarnessNsp.store()
        store.logConfig.saveSnapshots = true
        store.logConfig.snapshotsFilename = title

        // Trigger mutations and save snapshots.
        store.send(.mutating(.append(1)))
        store.saveSnapshotsIfNeeded()
        store.send(.mutating(.append(2)))
        store.saveSnapshotsIfNeeded()
        let collection = try ReducerSnapshotCollection.load(from: fileURL)

        // Expect snapshot count and latest values.
        #expect(collection.snapshots.count == 3)
        #expect(lastValuesStateString(in: collection) == "[1, 2]")
    }
}

extension LifecycleTests {
    @Suite @MainActor struct StateStoreLifecycleTests {}
}

extension LifecycleTests.StateStoreLifecycleTests {
    // Allocate then cancel store with lifecycle log enabled.
    // Expect allocate/cancel events and deallocation cleanup.
    @Test
    func storeLifecycleLogTracksEventsForStoreLifetime() async throws {
        // Set up lifecycle logging and weak reference.
        let originalLog = storeLifecycleLog
        defer { storeLifecycleLog = originalLog }
        storeLifecycleLog.enabled = true
        storeLifecycleLog.debug = false
        storeLifecycleLog.exclude = { _ in false }
        var trackedID: UUID?
        weak var weakStore: EffectHarnessNsp.Store?

        // Trigger allocation and cancellation.
        do {
            let store = EffectHarnessNsp.store()
            trackedID = store.id
            weakStore = store
            #expect(storeLifecycleLog.lastEvent[store.id]?.event == "Allocated")
            store.cancel()
            #expect(storeLifecycleLog.lastEvent[store.id]?.event == "Cancelled")
        }
        await Task.yield()

        // Expect deallocation and event cleanup.
        #expect(weakStore == nil)
        let unwrappedTrackedID = try #require(trackedID)
        #expect(storeLifecycleLog.lastEvent[unwrappedTrackedID] == nil)
    }
}

private func stateStoreSnapshotFileURL(title: String) throws -> URL {
    let root = try FileManager.default.url(
        for: .cachesDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    )
    return root
        .appendingPathComponent("ReducerLogs")
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
