import Combine
import Foundation
import Testing
@testable import ReducerArchitecture

private final class EffectPayload {
    var value: Int
    init(_ value: Int) { self.value = value }
}

private enum EffectIsolationNsp: StoreNamespace {
    typealias PublishedValue = Never
    typealias StoreEnvironment = Void
    typealias EffectAction = Never
    struct StoreState { var values: [Int] = [] }
    enum MutatingAction { case append(EffectPayload) }

    @MainActor
    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        MainActor.assertIsolated()
        switch action {
        case .append(let payload):
            state.values.append(payload.value)
            return .none
        }
    }
}

private func backgroundActionPublisher() -> AnyPublisher<EffectIsolationNsp.Store.Action, Never> {
    [1, 1, 2].publisher
        .subscribe(on: DispatchQueue(label: "ReducerArchitectureTests.BackgroundPublisher"))
        .map {
            #expect(!Thread.isMainThread)
            return EffectIsolationNsp.Store.Action.mutating(.append(EffectPayload($0)))
        }
        .eraseToAnyPublisher()
}

extension StateStoreTests {
    @Suite @MainActor struct EffectIsolationTests {}
}

extension StateStoreTests.EffectIsolationTests {
    @Test(arguments: [0, 1, 2])
    func asyncEffectsKeepNonSendableCapturesAndActionsOnMainActor(kind: Int) async throws {
        let store = EffectIsolationNsp.Store(.init(), env: ())
        let payload = EffectPayload(3)
        let action: @MainActor () async -> EffectIsolationNsp.Store.Action = {
            await Task.yield()
            MainActor.assertIsolated()
            return .mutating(.append(payload))
        }
        let effect: EffectIsolationNsp.Store.Effect
        switch kind {
        case 0: effect = .asyncAction(nil, action)
        case 1: effect = .asyncActionLatest(key: "value", nil, action)
        default: effect = .asyncActions { [await action(), await action()] }
        }
        let task = try #require(store.addEffect(effect))
        await task.value
        #expect(store.state.values == (kind == 2 ? [3, 3] : [3]))
        payload.value = 4
    }

    @Test(arguments: [false, true])
    func callbackSequencesReuseNonSendableActionsOnMainActor(latest: Bool) async throws {
        let store = EffectIsolationNsp.Store(.init(), env: ())
        let payload = EffectPayload(3)
        let observe: @MainActor (EffectIsolationNsp.Store.Effect.AsyncActionCallback) async -> Void = { send in
            send(.mutating(.append(payload)))
            await Task.yield()
            MainActor.assertIsolated()
            send(.mutating(.append(payload)))
        }
        let effect: EffectIsolationNsp.Store.Effect = latest
            ? .asyncActionSequenceLatest(key: "observe", observe)
            : .asyncActionSequence(observe)
        let task = try #require(store.addEffect(effect))
        await task.value
        #expect(store.state.values == [3, 3])
        payload.value = 4
    }

    @Test
    func publisherDeliversBackgroundActionsOnMainActorInOrder() async throws {
        let store = EffectIsolationNsp.Store(.init(), env: ())
        let task = try #require(store.addEffect(.publisher(backgroundActionPublisher())))
        await task.value
        #expect(store.state.values == [1, 1, 2])
        #expect(!store.isCancelled)
    }

    @Test(arguments: [false, true])
    func publisherCancellationCleansUpOnMainActor(cancelStore: Bool) async throws {
        let store = EffectIsolationNsp.Store(.init(), env: ())
        let subject = CurrentValueSubject<EffectIsolationNsp.Store.Action, Never>(.mutating(.append(EffectPayload(1))))
        let (cancellations, continuation) = AsyncStream<Void>.makeStream()
        var cancelled = cancellations.makeAsyncIterator()
        let publisher = subject.handleEvents(receiveCancel: {
            MainActor.assertIsolated()
            continuation.yield(())
            continuation.finish()
        }).eraseToAnyPublisher()
        var states = store.asyncValues(on: \.values).makeAsyncIterator()
        #expect(await states.next() == [])
        let task = try #require(store.addEffect(.publisher(publisher)))
        #expect(await states.next() == [1])

        if cancelStore { store.cancel() }
        else { await Task.detached { task.cancel() }.value }
        await task.value
        _ = try #require(await cancelled.next())
        subject.send(.mutating(.append(EffectPayload(2))))
        #expect(store.state.values == [1])
        #expect(store.isCancelled == cancelStore)
    }
}
