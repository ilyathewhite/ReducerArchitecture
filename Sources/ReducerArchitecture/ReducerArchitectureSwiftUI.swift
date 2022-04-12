//
//  File.swift
//  
//
//  Created by Ilya Belenkiy on 8/28/21.
//

#if canImport(SwiftUI)
import SwiftUI

public extension StateStore {
    func binding<Value>(
        _ keyPath: KeyPath<State, Value>,
        _ action: @escaping (Value) -> MutatingAction,
        animation: Animation? = nil
    )
    ->
    Binding<Value> where Value: Equatable
    {
        return Binding(
            get: { self.state[keyPath: keyPath] },
            set: {
                if self.state[keyPath: keyPath] != $0 {
                    if let animation = animation {
                        self.send(.mutating(action($0), animated: true, animation))
                    }
                    else {
                        self.send(.mutating(action($0)))
                    }
                }
            }
        )
    }

    func readOnlyBinding<Value>(_ keyPath: KeyPath<State, Value>) -> Binding<Value> {
        return Binding(
            get: { self.state[keyPath: keyPath] },
            set: { _ in
                assertionFailure()
                self.send(.noAction)
            }
        )
    }
}

public protocol StoreContentView: View {
    associatedtype StoreWrapper: StoreNamespace
    typealias Store = StoreWrapper.Store
    var store: Store { get }
    init(store: Store)
}

public protocol StoreUIWrapper {
    associatedtype ContentView: StoreContentView where ContentView.StoreWrapper == Self
}

public struct StoreUI<UIWrapper: StoreUIWrapper> {
    public let store: UIWrapper.Store
    public let _canActivateLink: (UIWrapper.Store.PublishedValue) -> Bool

    public init(
        _ store: UIWrapper.Store,
        canActivateLink: @escaping (UIWrapper.Store.PublishedValue) -> Bool = { _ in true }
    ) {
        self.store = store
        _canActivateLink = canActivateLink
    }

    public func makeView() -> UIWrapper.ContentView {
        UIWrapper.ContentView(store: store)
    }

    public var value: UIWrapper.Store.ValuePublisher { store.value }

    public func canActivateLink(_ value: UIWrapper.Store.PublishedValue) -> Bool {
        _canActivateLink(value)
    }
}

extension StoreUI: Identifiable {
    public var id: UIWrapper.Store.ID {
        store.id
    }
}

public struct ConnectOnAppear<S: AnyStore>: ViewModifier {
    public let store: S
    public let connect: () -> Void

    public func body(content: Content) -> some View {
        content
            .onAppear {
                guard !store.isConnectedToUI else { return }
                store.isConnectedToUI = true
                connect()
            }
            .id(store.id)
    }
}

public extension View {
    func connectOnAppear<S: AnyStore>(_ store: S, connect: @escaping () -> Void) -> some View {
        modifier(ConnectOnAppear(store: store, connect: connect))
    }
}

#endif
