//
//  NavigationTestProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/3/25.
//

import Combine

extension NavigationEnv {
    static func getStore(_ storeUI: some StoreUIContainer) -> any AnyStore {
        storeUI.store
    }

    static func getStore(_ container: some BasicReducerArchitectureVC) -> any AnyStore {
        container.store
    }
}

extension AnyStore {
    public func publishOnRequest(_ value: PublishedValue) async {
        while !hasRequest {
            await Task.yield()
        }
        publish(value)
    }
}

extension NavigationEnv {
    enum NavigationTestNode {
        case storeUI(any StoreUIContainer)
        case vc(any BasicReducerArchitectureVC)

        var store: (any AnyStore)? {
            switch self {
            case .storeUI(let storeUI):
                return NavigationEnv.getStore(storeUI)
            case .vc(let vc):
                return NavigationEnv.getStore(vc)
            }
        }
    }

    enum CurrentStoreError: Error {
        case typeMismatch
    }

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
    public func getStore<T: AnyStore>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T {
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

    @MainActor
    public static func testEnv() -> NavigationEnv {
        let currentStorePublisher: CurrentValueSubject<StoreInfo, Never> = .init(StoreInfo.placeholder)
        var stack: [NavigationTestNode] = []

        func updateCurrentStore() {
            guard let store = stack.last?.store else {
                assertionFailure()
                return
            }
            let timeIndex = currentStorePublisher.value.timeIndex + 1
            currentStorePublisher.send(.init(timeIndex: timeIndex, store: store))
        }

        return .init(
            currentIndex: {
                stack.count - 1
            },
            push: {
                stack.append(.storeUI($0))
                updateCurrentStore()
                return stack.count - 1
            },
            pushVC: {
                stack.append(.vc($0))
                updateCurrentStore()
                return stack.count - 1
            },
            replaceTop: {
                guard let last = stack.last else {
                    assertionFailure()
                    return 0
                }
                last.store?.cancel()

                stack[stack.count - 1] = .storeUI($0)
                updateCurrentStore()
                return stack.count - 1
            },
            popTo: { index in
                guard -1 <= index, index < stack.count else {
                    assertionFailure()
                    return
                }
                let k = stack.count - 1 - index
                // cancel order should be in reverse of push order
                var valuesToCancel: [any AnyStore] = []
                for _ in 0..<k {
                    guard let store = stack.removeLast().store else {
                        assertionFailure()
                        continue
                    }
                    valuesToCancel.append(store)
                }

                for value in valuesToCancel {
                    value.cancel()
                }

                updateCurrentStore()
            },
            currentStorePublisher: currentStorePublisher
        )
    }
}
