import Testing
@testable import ReducerArchitecture

private final class DistinctPayload: Equatable {
    var value: Int
    init(_ value: Int) { self.value = value }

    static func == (lhs: DistinctPayload, rhs: DistinctPayload) -> Bool {
        MainActor.assertIsolated()
        return lhs.value == rhs.value
    }
}

private enum DistinctValuesNsp: StoreNamespace {
    typealias StoreEnvironment = Void
    typealias EffectAction = Never
    typealias PublishedValue = Never

    struct StoreState {
        var text: String?
        var payload: DistinctPayload?
    }

    enum MutatingAction {
        case text(String?)
        case payload(DistinctPayload?)
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .text(let value): state.text = value
        case .payload(let value): state.payload = value
        }
        return .none
    }
}

extension StateStoreTests {
    @MainActor
    @Suite struct NativeDistinctValuesTests {}
}

extension StateStoreTests.NativeDistinctValuesTests {
    @Test
    func forAwaitSelectsSequenceAndPreservesInitialNilAndDistinctChanges() async {
        let store = DistinctValuesNsp.Store(.init(), env: ())
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let observation = Task { @MainActor in
            var received: [String?] = []
            for await value in store.distinctValues(on: \.text) {
                received.append(value)
                continuation.yield(())
            }
            return received
        }
        var readiness = ready.makeAsyncIterator()
        _ = await readiness.next()
        for text: String? in [nil, "a", "a", "ab", "ab", nil, nil, "a"] {
            store.send(.mutating(.text(text)))
        }
        store.cancel()
        #expect(await observation.value == [nil, "a", "ab", nil, "a"])
        continuation.finish()
    }

    @Test
    func nonSendableValuesCompareOnMainActorAndSubscriptionsFinishOnDeinit() async {
        var store: DistinctValuesNsp.Store? = .init(.init(), env: ())
        weak var weakStore = store
        let firstValue = DistinctPayload(1)
        let equalValue = DistinctPayload(1)
        let secondValue = DistinctPayload(2)
        let firstValues: MainActorSequence<DistinctPayload?> = store!.distinctValues(on: \.payload)
        var first = firstValues.makeAsyncIterator()
        store!.send(.mutating(.payload(firstValue)))
        let lateValues: MainActorSequence<DistinctPayload?> = store!.distinctValues(on: \.payload)
        var late = lateValues.makeAsyncIterator()
        store!.send(.mutating(.payload(equalValue)))
        store!.send(.mutating(.payload(secondValue)))
        store = nil
        #expect(weakStore == nil)

        let initial = await first.next()
        #expect(initial != nil)
        #expect(initial! == nil)
        #expect(await first.next()! === firstValue)
        #expect(await first.next()! === secondValue)
        #expect(await first.next() == nil)
        #expect(await late.next()! === firstValue)
        #expect(await late.next()! === secondValue)
        #expect(await late.next() == nil)
    }

    @Test
    func customComparisonCanCaptureMainActorState() async {
        let store = DistinctValuesNsp.Store(.init(), env: ())
        var comparisons = 0
        let values: MainActorSequence<String?> = store.distinctValues(on: \.text, compare: { lhs, rhs in
            MainActor.assertIsolated()
            comparisons += 1
            return lhs?.lowercased() == rhs?.lowercased()
        })
        var iterator = values.makeAsyncIterator()
        for text: String? in [nil, "A", "a", "B", "b", nil] { store.send(.mutating(.text(text))) }
        store.cancel()
        var received: [String?] = []
        while let value = await iterator.next() { received.append(value) }
        #expect(received == [nil, "A", "B", nil])
        #expect(comparisons > 0)
    }

    @Test
    func cancellingObservationLeavesStoreAndLaterSubscriptionsActive() async {
        let store = DistinctValuesNsp.Store(.init(text: "initial"), env: ())
        let (ready, continuation) = AsyncStream<Void>.makeStream()
        let observation = Task { @MainActor in
            for await _ in store.distinctValues(on: \.text) { continuation.yield(()) }
        }
        var readiness = ready.makeAsyncIterator()
        _ = await readiness.next()
        observation.cancel()
        await observation.value
        continuation.finish()
        #expect(!store.isCancelled)

        let values: MainActorSequence<String?> = store.distinctValues(on: \.text)
        var later = values.makeAsyncIterator()
        #expect(await later.next() == .some("initial"))
        store.send(.mutating(.text("updated")))
        #expect(await later.next() == .some("updated"))
    }
}
