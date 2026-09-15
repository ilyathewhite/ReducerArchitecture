import Testing
@testable import ReducerArchitecture

private final class BindingPayload {
    let value: Int
    init(_ value: Int) { self.value = value }
}

private enum NativeBindingNsp: StoreNamespace {
    typealias PublishedValue = Int?
    typealias StoreEnvironment = Void
    typealias EffectAction = Never

    struct StoreState {
        var value: BindingPayload?
        var received: [BindingPayload?] = []
        var outputs: [Int?] = []
    }

    enum MutatingAction {
        case set(BindingPayload?)
        case record(BindingPayload?)
        case output(Int?)
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .set(let value): state.value = value
        case .record(let value): state.received.append(value)
        case .output(let value): state.outputs.append(value)
        }
        return .none
    }
}

extension StateStoreTests {
    @MainActor
    @Suite struct NativeBindingTests {}
}

extension StateStoreTests.NativeBindingTests {
    @Test
    func bindingRegistersSynchronouslyAndPreservesDistinctNonSendableValues() async {
        let source = NativeBindingNsp.Store(.init(), env: ())
        let target = NativeBindingNsp.Store(.init(), env: ())
        let first = BindingPayload(1)
        let second = BindingPayload(2)
        let task = target.bind(
            to: source, on: \.value, with: { .mutating(.record($0)) },
            compare: { $0 === $1 }
        )
        for value in [first, first, nil, nil, second] { source.send(.mutating(.set(value))) }
        source.cancel()
        await task?.value
        #expect(target.state.received.count == 4)
        #expect(target.state.received[0] == nil)
        #expect(target.state.received[1] === first)
        #expect(target.state.received[2] == nil)
        #expect(target.state.received[3] === second)
        #expect(!target.isCancelled)
    }

    @Test
    func publishedBindingDrainsBurstBeforeCancellingTarget() async {
        let source = NativeBindingNsp.Store(.init(), env: ())
        let target = NativeBindingNsp.Store(.init(), env: ())
        let task = target.bindPublishedValue(of: source) { .mutating(.output($0)) }
        source.publish(1)
        source.publish(nil)
        source.publish(1)
        source.cancel()
        await task?.value
        #expect(target.state.outputs == [1, nil, 1])
        #expect(target.isCancelled)
    }

    @Test
    func cancellingTargetDetachesBindingsWithoutCancellingSource() async {
        let source = NativeBindingNsp.Store(.init(), env: ())
        let target = NativeBindingNsp.Store(.init(), env: ())
        let stateTask = target.bind(to: source, on: \.value, with: { .mutating(.record($0)) }, compare: { $0 === $1 })
        let outputTask = target.bindPublishedValue(of: source) { .mutating(.output($0)) }
        target.cancel()
        await stateTask?.value
        await outputTask?.value
        #expect(!source.isCancelled)
        #expect(!source.hasRequest)
        #expect(target.state.received.isEmpty)
        #expect(target.state.outputs.isEmpty)
    }

    @Test
    func stateSubscriptionsHaveIndependentCurrentValuesAndCompleteOnDeinit() async {
        var source: NativeBindingNsp.Store? = .init(.init(), env: ())
        let value = BindingPayload(42)
        var first = source!.asyncValues(on: \.value).makeAsyncIterator()
        source!.send(.mutating(.set(value)))
        var late = source!.asyncValues(on: \.value).makeAsyncIterator()
        source = nil
        let initial = await first.next()
        #expect(initial != nil)
        #expect(initial! == nil)
        #expect(await first.next()! === value)
        #expect(await late.next()! === value)
        #expect(await first.next() == nil)
        #expect(await late.next() == nil)
    }
}
