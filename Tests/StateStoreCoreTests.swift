import Combine
import Testing
@testable import ReducerArchitecture

private struct CounterEnvironment {}

private enum CounterNsp: StoreNamespace {
    typealias PublishedValue = Void
    typealias StoreEnvironment = CounterEnvironment

    enum MutatingAction {
        case set(Int)
    }

    typealias EffectAction = Never

    struct StoreState: Equatable {
        var value: Int
        var mutationCount: Int
    }
}

extension CounterNsp {
    @MainActor
    static func store(value: Int = 0) -> Store {
        .init(.init(value: value, mutationCount: 0), env: .init())
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .set(let value):
            state.value = value
            state.mutationCount += 1
            return .none
        }
    }
}

extension StateStoreTests {
    @Suite @MainActor struct StateStoreCoreTests {}
}

extension StateStoreTests.StateStoreCoreTests {
    // MARK: - Publishers

    // Observe updates stream with duplicate sends.
    // Expect only distinct post-initial updates.
    @Test
    func updatesPublishesOnlyDistinctChangesAfterInitialValue() async {
        // Set up store and subscriber.
        let store = CounterNsp.store(value: 0)
        var received: [Int] = []
        let cancellable = store.updates(on: \.value).sink { value in
            received.append(value)
        }

        // Trigger duplicate and distinct mutations.
        store.send(.mutating(.set(0)))
        store.send(.mutating(.set(1)))
        store.send(.mutating(.set(1)))
        store.send(.mutating(.set(2)))

        // Expect only distinct updates.
        #expect(received == [1, 2])
        _ = cancellable
    }

    // Observe distinctValues stream with duplicate sends.
    // Expect initial value and distinct updates.
    @Test
    func distinctValuesIncludesInitialValueAndSkipsDuplicates() async {
        // Set up store and subscriber.
        let store = CounterNsp.store(value: 0)
        var received: [Int] = []
        let cancellable = store.distinctValues(on: \.value).sink { value in
            received.append(value)
        }

        // Trigger duplicate and distinct mutations.
        store.send(.mutating(.set(0)))
        store.send(.mutating(.set(1)))
        store.send(.mutating(.set(1)))
        store.send(.mutating(.set(2)))

        // Expect initial and distinct updates.
        #expect(received == [0, 1, 2])
        _ = cancellable
    }

    // Bind source values into target reducer.
    // Expect only deduped source updates are forwarded.
    @Test
    func bindForwardsDistinctSourceValues() async {
        // Set up source and target stores.
        let source = CounterNsp.store(value: 5)
        let target = CounterNsp.store(value: 0)

        // Start long-lived binding effect.
        let bindTask = Task { @MainActor in
            await target.bind(to: source, on: \.value, with: { .mutating(.set($0)) })?.value
            target.cancel()
        }

        var didSendUpdates = false
        var targetValues: [Int] = []
        for await value in target.asyncValues(on: \.value) {
            targetValues.append(value)

            // Wait for initial bind propagation, then emit a burst with one duplicate.
            if value == 5 && !didSendUpdates {
                didSendUpdates = true
                source.send(.mutating(.set(100)))
                source.send(.mutating(.set(6)))
                source.send(.mutating(.set(6)))
                source.send(.mutating(.set(7)))
                source.cancel()
            }

            // Stop collecting once the final expected forwarded value arrives.
            if value == 7 {
                break
            }
        }

        // Expect initial value plus deduped source updates.
        #expect(targetValues == [0, 5, 100, 6, 7])
        #expect(target.state.mutationCount == 4)
        await bindTask.value
    }

    // Start two asyncLatest effects under same key.
    // Expect only latest action mutates state.
    @Test
    func asyncActionLatestCancelsPreviousActionWithSameKey() async {
        // Set up store.
        let store = CounterNsp.store(value: 0)

        // Trigger competing asyncLatest actions.
        let first = store.addEffect(.asyncActionLatest(key: "load") {
            try? await Task.sleep(for: .seconds(0.2))
            return .mutating(.set(1))
        })
        let second = store.addEffect(.asyncActionLatest(key: "load") {
            try? await Task.sleep(for: .seconds(0.02))
            return .mutating(.set(2))
        })
        await first?.value
        await second?.value

        // Expect only latest result applies.
        #expect(store.state.value == 2)
        #expect(store.state.mutationCount == 1)
    }

    // Cancel parent store with child attached.
    // Expect parent ignores later actions and child cancels.
    @Test
    func cancelStopsStateMutationsAndCancelsChildren() {
        // Set up parent and child stores.
        let parent = CounterNsp.store(value: 3)
        let child = CounterNsp.store(value: 1)
        parent.children["child"] = child

        // Trigger cancellation then mutation.
        parent.cancel()
        parent.send(.mutating(.set(10)))

        // Expect cancellation effects.
        #expect(parent.isCancelled)
        #expect(parent.environment == nil)
        #expect(parent.state.value == 3)
        #expect(child.isCancelled)
    }
}
