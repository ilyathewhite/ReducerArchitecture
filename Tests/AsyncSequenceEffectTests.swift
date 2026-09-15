import AsyncAlgorithms
import Testing
@testable import ReducerArchitecture

private final class SequencePayload {
    let value: Int
    init(_ value: Int) { self.value = value }
}

private enum AsyncSequenceNsp: StoreNamespace {
    typealias PublishedValue = Never
    struct StoreEnvironment {
        var wait: (Int) async -> Void = { _ in }
    }
    struct StoreState { var values: [Int?] = [] }
    enum MutatingAction { case append(SequencePayload?) }
    enum EffectAction {
        case appendAfterWaiting(Int)
        case observe(MainActorSequence<Store.Action>)
    }

    @MainActor
    static func store() -> Store { Store(.init(), env: .init()) }

    @MainActor
    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        MainActor.assertIsolated()
        switch action {
        case .append(let payload):
            state.values.append(payload?.value)
            return .none
        }
    }

    @MainActor
    static func runEffect(_ env: StoreEnvironment, _ state: StoreState, _ action: EffectAction) -> Store.Effect {
        switch action {
        case .appendAfterWaiting(let value):
            return .asyncAction {
                await env.wait(value)
                return .mutating(.append(SequencePayload(value)))
            }
        case .observe(let values):
            return .asyncSequence(values)
        }
    }
}

extension StateStoreTests {
    @Suite @MainActor struct AsyncSequenceEffectTests {}
}

extension StateStoreTests.AsyncSequenceEffectTests {
    @Test
    func initialValueAndImmediateBurstPreserveNonSendablePayloadsNilAndDuplicates() async throws {
        let store = AsyncSequenceNsp.store()
        let source = MainActorValueSource<SequencePayload?>(initialValue: nil)
        let task = try #require(store.addEffect(.asyncSequence(source.values.map { .mutating(.append($0)) })))
        let payload = SequencePayload(1)
        source.send(payload)
        source.send(payload)
        source.send(nil)
        source.send(SequencePayload(2))
        source.finish()
        await task.value

        #expect(store.state.values == [nil, 1, 1, nil, 2])
        #expect(!store.isCancelled)
    }

    @Test
    func publishedValuesSubscribeBeforeReturningFromAddEffect() async throws {
        let store = AsyncSequenceNsp.store()
        let source = BaseViewModel<Int?>()
        let task = try #require(store.addEffect(.asyncSequence(source.asyncValues.map {
            .mutating(.append($0.map(SequencePayload.init)))
        })))
        for value in [1, nil, nil, 2, 2] { source.publish(value) }
        source.cancel()
        await task.value

        #expect(store.state.values == [1, nil, nil, 2, 2])
        #expect(!store.isCancelled)
    }

    @Test
    func acceptsAsyncAlgorithmsPipeline() async throws {
        let store = AsyncSequenceNsp.store()
        let values = [1, 1, 2, 2, 3].async.removeDuplicates().map {
            AsyncSequenceNsp.Store.Action.mutating(.append(SequencePayload($0)))
        }
        let task = try #require(store.addEffect(.asyncSequence(values)))
        await task.value
        #expect(store.state.values == [1, 2, 3])
    }

    @Test(arguments: [false, true])
    func cancellationStopsPendingMappingWithoutCancellingSource(cancelStore: Bool) async throws {
        let store = AsyncSequenceNsp.store()
        let source = MainActorValueSource<SequencePayload?>()
        var survivor = source.values.makeAsyncIterator()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let waiting = MainActorSequence<SequencePayload?> {
            var iterator = source.values.makeAsyncIterator()
            return {
                continuation.yield(())
                return await iterator.next()
            }
        }
        var mappedCount = 0
        let task = try #require(store.addEffect(.asyncSequence(waiting.map {
            mappedCount += 1
            return .mutating(.append($0))
        })))
        var ready = started.makeAsyncIterator()
        await ready.next()
        source.send(SequencePayload(1))
        if cancelStore { store.cancel() }
        else { task.cancel() }
        await task.value

        #expect(mappedCount == 0)
        #expect(store.state.values.isEmpty)
        #expect(store.isCancelled == cancelStore)
        #expect(!source.isFinished)
        #expect(await survivor.next()??.value == 1)
    }

    @Test
    func cancellingBeforeTaskStartsSkipsMapping() async throws {
        let store = AsyncSequenceNsp.store()
        let source = MainActorValueSource<SequencePayload?>(initialValue: SequencePayload(1))
        var mappedCount = 0
        let task = try #require(store.addEffect(.asyncSequence(source.values.map {
            mappedCount += 1
            return .mutating(.append($0))
        })))
        task.cancel()
        await task.value
        #expect(mappedCount == 0)
        #expect(store.state.values.isEmpty)
    }

    @Test
    func releasingStoreEndsObservationWithoutFinishingSource() async throws {
        var store: AsyncSequenceNsp.Store? = AsyncSequenceNsp.store()
        weak var weakStore = store
        let source = MainActorValueSource<AsyncSequenceNsp.Store.Action>(
            initialValue: .mutating(.append(SequencePayload(1)))
        )
        var states = try #require(store?.asyncValues(on: \.values).makeAsyncIterator())
        let task = try #require(store?.addEffect(.asyncSequence(source.values)))
        #expect(await states.next() == [])
        #expect(await states.next() == [1])
        store = nil
        #expect(weakStore == nil)
        weakStore?.cancel()
        await task.value
        #expect(!source.isFinished)
    }

    @Test(arguments: [false, true])
    func asyncActionReleasesStoreWhileAwaitingNestedSequence(latest: Bool) async throws {
        var store: AsyncSequenceNsp.Store? = AsyncSequenceNsp.store()
        weak var weakStore = store
        let source = MainActorValueSource<AsyncSequenceNsp.Store.Action>()
        defer { source.finish() }
        var survivor = source.values.makeAsyncIterator()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        let waiting = MainActorSequence<AsyncSequenceNsp.Store.Action> {
            var iterator = source.values.makeAsyncIterator()
            return {
                continuation.yield(())
                return await iterator.next()
            }
        }
        let effect: AsyncSequenceNsp.Store.Effect = latest
            ? .asyncActionLatest(key: "observe", nil, { .effect(.observe(waiting)) })
            : .asyncAction(nil, { .effect(.observe(waiting)) })
        let task = try #require(store?.addEffect(effect))
        var ready = started.makeAsyncIterator()
        _ = try #require(await ready.next())

        store = nil
        #expect(weakStore == nil)
        weakStore?.cancel()
        await task.value

        #expect(!source.isFinished)
        source.send(.none)
        _ = try #require(await survivor.next())
    }

    @Test
    func cancelledStoreDoesNotSubscribe() {
        let store = AsyncSequenceNsp.store()
        store.cancel()
        var subscriptions = 0
        let values = MainActorSequence<AsyncSequenceNsp.Store.Action> {
            subscriptions += 1
            return { nil }
        }
        #expect(store.addEffect(.asyncSequence(values)) == nil)
        #expect(subscriptions == 0)
    }

    @Test
    func completionAwaitsNestedEffectsWithoutBlockingLaterActions() async throws {
        let store = AsyncSequenceNsp.store()
        let (started, startContinuation) = AsyncStream<Int>.makeStream()
        var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
        store.environment = .init(wait: { value in
            await withCheckedContinuation {
                continuations[value] = $0
                startContinuation.yield(value)
            }
        })
        let actions: [AsyncSequenceNsp.Store.Action] = [
            .effect(.appendAfterWaiting(1)), .effect(.appendAfterWaiting(2))
        ]
        let task = try #require(store.addEffect(.asyncSequence(actions.async)))
        var finished = false
        let completion = Task { @MainActor in
            await task.value
            finished = true
        }
        var iterator = started.makeAsyncIterator()
        var startedValues: [Int] = []
        for _ in 0..<2 { startedValues.append(try #require(await iterator.next())) }
        #expect(Set(startedValues) == [1, 2])
        #expect(!finished)

        continuations[1]?.resume()
        continuations[2]?.resume()
        await completion.value
        #expect(finished)
        #expect(Set(store.state.values.compactMap { $0 }) == [1, 2])
    }
}
