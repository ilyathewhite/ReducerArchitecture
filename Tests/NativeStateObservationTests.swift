import Combine
import Testing
@testable import ReducerArchitecture

private final class ObservationPayload: Equatable {
    let value: Int
    init(_ value: Int) { self.value = value }

    static func == (lhs: ObservationPayload, rhs: ObservationPayload) -> Bool {
        MainActor.assertIsolated()
        return lhs.value == rhs.value
    }
}

private enum StateObservationNsp: StoreNamespace {
    typealias StoreEnvironment = Void
    typealias EffectAction = Never
    typealias PublishedValue = Never

    struct StoreState { var value: ObservationPayload? }
    enum MutatingAction { case set(ObservationPayload?) }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .set(let value): state.value = value
        }
        return .none
    }
}

extension StateStoreTests {
    @MainActor
    @Suite struct NativeStateObservationTests {}
}

extension StateStoreTests.NativeStateObservationTests {
    @Test(arguments: [false, true])
    func valuesAndUpdatesMatchPublishers(onlyUpdates: Bool) async {
        let store = StateObservationNsp.Store(.init(), env: ())
        let sequence: MainActorSequence<ObservationPayload?> = onlyUpdates
            ? store.updates(on: \.value) : store.values(on: \.value)
        let publisher: AnyPublisher<ObservationPayload?, Never> = onlyUpdates
            ? store.updates(on: \.value) : store.values(on: \.value)
        var iterator = sequence.makeAsyncIterator()
        var published: [Int?] = []
        let subscription = publisher.sink { published.append($0?.value) }
        defer { subscription.cancel() }

        for value: Int? in [nil, 1, 1, nil, nil, 2, 2] {
            store.send(.mutating(.set(value.map(ObservationPayload.init))))
        }
        store.cancel()
        var received: [Int?] = []
        while let value = await iterator.next() { received.append(value?.value) }

        #expect(received == published)
        #expect(received == (onlyUpdates ? [1, nil, 2] : [nil, nil, 1, 1, nil, nil, 2, 2]))
    }

    @Test
    func updatesUseEachSubscriptionsCurrentValueAndFinishOnDeinit() async {
        var store: StateObservationNsp.Store? = .init(.init(value: ObservationPayload(1)), env: ())
        weak var weakStore = store
        var comparisons = 0
        let updates: MainActorSequence<ObservationPayload?> = store!.updates(on: \.value, compare: { lhs, rhs in
            MainActor.assertIsolated()
            comparisons += 1
            return lhs?.value == rhs?.value
        })
        var first = updates.makeAsyncIterator()
        store!.send(.mutating(.set(ObservationPayload(1))))
        store!.send(.mutating(.set(ObservationPayload(2))))
        var late = updates.makeAsyncIterator()
        for value: Int? in [2, 1, 1, nil, nil] {
            store!.send(.mutating(.set(value.map(ObservationPayload.init))))
        }
        store = nil
        #expect(weakStore == nil)

        var firstValues: [Int?] = []
        while let value = await first.next() { firstValues.append(value?.value) }
        var lateValues: [Int?] = []
        while let value = await late.next() { lateValues.append(value?.value) }
        #expect(firstValues == [2, 1, nil])
        #expect(lateValues == [1, nil])
        #expect(comparisons > 0)
    }

    @Test
    func forAwaitSelectsNativeOverloadsOnCancelledStore() async {
        let store = StateObservationNsp.Store(.init(value: ObservationPayload(1)), env: ())
        store.cancel()
        var received = 0
        for await _ in store.values(on: \.value) { received += 1 }
        for await _ in store.updates(on: \.value) { received += 1 }
        for await _ in store.updates(on: \.value, compare: { $0?.value == $1?.value }) { received += 1 }
        #expect(received == 0)
    }

    @Test
    func cancellingPendingUpdateLeavesSourceActive() async {
        let store = StateObservationNsp.Store(.init(), env: ())
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let updates: MainActorSequence<ObservationPayload?> = store.updates(on: \.value, compare: { lhs, rhs in
            continuation.yield(())
            return lhs == rhs
        })
        var iterator = updates.makeAsyncIterator()
        store.send(.mutating(.set(nil)))
        let observation = Task { @MainActor in await iterator.next() == nil }
        var readiness = started.makeAsyncIterator()
        await readiness.next()
        observation.cancel()
        #expect(await observation.value)
        continuation.finish()
        #expect(!store.isCancelled)

        var later = store.updates(on: \.value).makeAsyncIterator()
        store.send(.mutating(.set(ObservationPayload(1))))
        #expect(await later.next()??.value == 1)
        store.cancel()
        #expect(await later.next() == nil)
    }

    @Test
    func inlineUpdatesEffectSkipsInitialValueAndRegistersBeforeReturning() async {
        let source = StateObservationNsp.Store(.init(value: ObservationPayload(1)), env: ())
        let target = StateObservationNsp.Store(.init(), env: ())
        var iterator = target.values(on: \.value).makeAsyncIterator()
        let task = target.addEffect(.asyncSequence(source.updates(on: \.value).map { .mutating(.set($0)) }))
        source.send(.mutating(.set(ObservationPayload(1))))
        source.send(.mutating(.set(ObservationPayload(2))))
        source.send(.mutating(.set(nil)))
        source.send(.mutating(.set(ObservationPayload(3))))
        source.cancel()
        await task?.value

        #expect(!target.isCancelled)
        target.cancel()
        var received: [Int?] = []
        while let value = await iterator.next() { received.append(value?.value) }
        #expect(received == [nil, 2, nil, 3])
    }
}
