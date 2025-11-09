//
//  NavigationTestProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/3/25.
//

import Combine

class NavigationTestProxy: NavigationProxy {
    enum Placeholder: StoreNamespace {
        typealias PublishedValue = Void
        typealias StoreEnvironment = Never
        typealias MutatingAction = Void
        typealias EffectAction = Never
        struct StoreState {}

        @MainActor
        static func store() -> Store {
            .init(.init(), reducer: reducer())
        }
    }

    @MainActor
    struct StoreInfo {
        let timeIndex: Int
        let store: any BasicViewModel

        static let placeholder = Self.init(timeIndex: -1, store: Placeholder.store())
    }

    enum CurrentStoreError: Error {
        case typeMismatch
    }

    public private(set) var stack: [any StoreUIContainer] = []
    let currentStorePublisher: CurrentValueSubject<StoreInfo, Never> = .init(.placeholder)

    /// Returns the store of a particular type for a given time index.
    ///
    /// Used only for testing.
    @MainActor
    public func getStore<T: StoreNamespace>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T.Store {
        let value = await currentStorePublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let store = value?.store as? T.Store else {
            throw CurrentStoreError.typeMismatch
        }
        timeIndex += 1
        return store
    }

    /// Returns the store of a particular type for a given time index.
    ///
    /// Used only for testing.
    @MainActor
    public func getStore<T: BasicViewModel>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T {
        let value = await currentStorePublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let store = value?.store as? T else {
            throw CurrentStoreError.typeMismatch
        }
        timeIndex += 1
        return store
    }

    @MainActor
    /// Used only for testing.
    public func backAction() {
        return pop()
    }

    func updateCurrentStore() {
        guard let store = stack.last?.anyStore else {
            assertionFailure()
            return
        }
        let timeIndex = currentStorePublisher.value.timeIndex + 1
        currentStorePublisher.send(.init(timeIndex: timeIndex, store: store))
    }

    var currentIndex: Int {
        stack.count - 1
    }

    public func push<Nsp: StoreUINamespace>(_ storeUI: StoreUI<Nsp>) -> Int {
        stack.append(storeUI)
        updateCurrentStore()
        return stack.count - 1
    }

    public func replaceTop<Nsp: StoreUINamespace>(with storeUI: StoreUI<Nsp>) -> Int {
        guard let last = stack.last else {
            assertionFailure()
            return 0
        }
        last.cancel()

        stack[stack.count - 1] = storeUI
        updateCurrentStore()
        return stack.count - 1
    }

    public func popTo(_ index: Int) {
        guard -1 <= index, index < stack.count else {
            assertionFailure()
            return
        }
        let k = stack.count - 1 - index
        // cancel order should be in reverse of push order
        var valuesToCancel: [any BasicViewModel] = []
        for _ in 0..<k {
            let store = stack.removeLast()
            valuesToCancel.append(store.anyStore)
        }

        for value in valuesToCancel {
            value.cancel()
        }

        updateCurrentStore()
    }
}
