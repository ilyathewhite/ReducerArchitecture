import Testing
#if canImport(SwiftUI)
import SwiftUI
@testable import ReducerArchitecture

private enum SwiftUIHarnessNsp: StoreUINamespace {
    typealias PublishedValue = Void
    typealias StoreEnvironment = Never
    typealias EffectAction = Never

    enum MutatingAction {
        case set(Int)
        case setOptional(Int?)
    }

    struct StoreState: Equatable {
        var value = 0
        var mutationCount = 0
        var optionalValue: Int?
    }

    struct ContentView: StoreContentView {
        typealias Nsp = SwiftUIHarnessNsp
        let store: Store

        init(_ viewModel: Store) {
            self.store = viewModel
        }

        var body: some View {
            EmptyView()
        }
    }
}

extension SwiftUIHarnessNsp {
    @MainActor
    static func store(value: Int = 0) -> Store {
        .init(.init(value: value, mutationCount: 0), env: nil)
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .set(let value):
            state.value = value
            state.mutationCount += 1
            return .none
        case .setOptional(let value):
            state.optionalValue = value
            state.mutationCount += 1
            return .none
        }
    }
}

extension SwiftUIStoreTests {
    @Suite @MainActor struct StateStoreSwiftUITests {}
}

extension SwiftUIStoreTests.StateStoreSwiftUITests {
    // MARK: - Bindings

    @Test(arguments: [false, true])
    func bindingDoesNotRetainStoreAndIgnoresWritesAfterRelease(animated: Bool) {
        var store: SwiftUIHarnessNsp.Store? = SwiftUIHarnessNsp.store(value: 3)
        weak var weakStore = store
        var actionCount = 0
        let binding = store!.binding(\.value, { value in
            actionCount += 1
            return .set(value)
        }, animation: animated ? .default : nil)

        #expect(binding.wrappedValue == 3)
        store!.send(.mutating(.set(5)))
        #expect(binding.wrappedValue == 5)

        binding.wrappedValue = 5
        #expect(actionCount == 0)
        #expect(store!.state.mutationCount == 1)

        binding.wrappedValue = 7
        #expect(actionCount == 1)
        #expect(store!.state.value == 7)
        #expect(store!.state.mutationCount == 2)

        store = nil
        #expect(weakStore == nil)
        #expect(binding.wrappedValue == 7)
        binding.wrappedValue = 11
        #expect(actionCount == 1)
        #expect(binding.wrappedValue == 7)
    }

    @Test
    func bindingPreservesLastReadNilAfterStoreRelease() {
        var store: SwiftUIHarnessNsp.Store? = .init(.init(optionalValue: 42), env: nil)
        weak var weakStore = store
        let binding = store!.binding(\.optionalValue, { .setOptional($0) })
        #expect(binding.wrappedValue == 42)

        store!.send(.mutating(.setOptional(nil)))
        #expect(binding.wrappedValue == nil)
        store = nil

        #expect(weakStore == nil)
        #expect(binding.wrappedValue == nil)
        binding.wrappedValue = 7
        #expect(binding.wrappedValue == nil)
    }

    // Write through animated binding setter.
    // Expect state mutation and mutation count increment.
    @Test
    func bindingWithAnimationMutatesState() {
        // Set up store and animated binding.
        let store = SwiftUIHarnessNsp.store(value: 0)
        let binding = store.binding(\.value, { .set($0) }, animation: .default)

        // Trigger binding write.
        binding.wrappedValue = 7

        // Expect state change through reducer.
        #expect(store.state.value == 7)
        #expect(store.state.mutationCount == 1)
    }

    // Read store value via read-only binding.
    // Expect getter reflects current state.
    @Test
    func readOnlyBindingReadsCurrentState() {
        // Set up store and read-only binding.
        let store = SwiftUIHarnessNsp.store(value: 3)
        let binding = store.readOnlyBinding(\.value)

        // Trigger store update.
        store.send(.mutating(.set(9)))

        // Expect binding mirrors latest value.
        #expect(binding.wrappedValue == 9)
    }

    @Test
    func readOnlyBindingDoesNotRetainStoreAndPreservesLastReadValues() {
        var store: SwiftUIHarnessNsp.Store? = .init(.init(value: 3, optionalValue: 42), env: nil)
        weak var weakStore = store
        let binding = store!.readOnlyBinding(\.value)
        let optionalBinding = store!.readOnlyBinding(\.optionalValue)
        #expect(binding.wrappedValue == 3)
        #expect(optionalBinding.wrappedValue == 42)

        store!.send(.mutating(.set(9)))
        store!.send(.mutating(.setOptional(nil)))
        #expect(binding.wrappedValue == 9)
        #expect(optionalBinding.wrappedValue == nil)
        store = nil

        #expect(weakStore == nil)
        #expect(binding.wrappedValue == 9)
        #expect(optionalBinding.wrappedValue == nil)
    }

    // MARK: - Namespace Defaults

    // Call default updateNavigationCount implementation.
    // Expect no-op leaves state unchanged.
    @Test
    func defaultUpdateNavigationCountIsNoOp() {
        // Set up store snapshot.
        let store = SwiftUIHarnessNsp.store(value: 5)
        let before = store.state

        // Trigger default namespace hook.
        SwiftUIHarnessNsp.updateNavigationCount(store)

        // Expect state remains unchanged.
        #expect(store.state == before)
    }

    // Build contentView from StoreUINamespace store.
    // Expect view holds same store instance.
    @Test
    func contentViewUsesStoreAsViewModel() {
        // Set up store.
        let store = SwiftUIHarnessNsp.store(value: 8)

        // Trigger contentView construction.
        let contentView = store.contentView

        // Expect view references the same store.
        #expect(contentView.store === store)
    }
}
#endif
