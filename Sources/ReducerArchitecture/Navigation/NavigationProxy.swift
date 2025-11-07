//
//  NavigationProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/3/25.
//

import Combine

private enum NavigationEnvPlaceholder: StoreNamespace {
    typealias PublishedValue = Void
    typealias StoreEnvironment = Never
    typealias MutatingAction = Void
    typealias EffectAction = Never
    struct StoreState {}
}

extension NavigationEnvPlaceholder {
    @MainActor
    static func store() -> Store {
        .init(.init(), reducer: reducer())
    }
}

public struct NavigationEnv {
    @MainActor
    struct StoreInfo {
        let timeIndex: Int
        let store: any AnyStore

        static let placeholder = Self.init(timeIndex: -1, store: NavigationEnvPlaceholder.store())
    }

    /// Returns the index of the top component on the stack.
    public let currentIndex: @MainActor () -> Int

    /// Pushes the next UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    public let push: @MainActor (any StoreUIContainer & Hashable) -> Int

    /// Replaces the last UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    public let replaceTop: @MainActor (any StoreUIContainer & Hashable) -> Int

    /// Pops the navigation stack to the component at `index`.
    public let popTo: @MainActor (_ index: Int) -> Void

    /// Provides the navigation stack top store whenever the navigation stack changes.
    ///
    /// Available only when testing.
    let currentStorePublisher: CurrentValueSubject<StoreInfo, Never>

    public init(
        currentIndex: @escaping () -> Int,
        push: @escaping (any StoreUIContainer & Hashable) -> Int,
        replaceTop: @escaping (any StoreUIContainer & Hashable) -> Int,
        popTo: @escaping (_: Int) -> Void
    ) {
        self.init(
            currentIndex: currentIndex,
            push: push,
            replaceTop: replaceTop,
            popTo: popTo,
            currentStorePublisher: .init(.placeholder)
        )
    }

    init(currentIndex: @escaping () -> Int,
         push: @escaping (any StoreUIContainer & Hashable) -> Int,
         replaceTop: @escaping (any StoreUIContainer & Hashable) -> Int,
         popTo: @escaping (_: Int) -> Void,
         currentStorePublisher: CurrentValueSubject<StoreInfo, Never>
    ) {
        self.currentIndex = currentIndex
        self.push = push
        self.replaceTop = replaceTop
        self.popTo = popTo
        self.currentStorePublisher = currentStorePublisher
    }
}

@MainActor
public extension NavigationEnv {
    func pop() {
        popTo(currentIndex() - 1)
    }
}
