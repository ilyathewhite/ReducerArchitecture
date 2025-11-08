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
            }
        )
    }
}

@MainActor
public protocol StoreContentView: View {
    associatedtype Nsp: StoreNamespace
    typealias Store = Nsp.Store
    var store: Store { get }
    init(store: Store)
}

public protocol StoreUINamespace: StoreNamespace {
    associatedtype ContentView: StoreContentView where ContentView.Nsp == Self
    static func updateNavigationCount(_ store: Store) -> Void
}

public extension StoreUINamespace {
    static func updateNavigationCount(_ store: Store) -> Void {}
}

public extension StateStore where Nsp: StoreUINamespace {
    var contentView: Nsp.ContentView {
        Nsp.ContentView(store: self)
    }
}

/// A type that can be used to create a view from a store. Used in APIs related to navigation.
///
/// `store.contentView` also provides a way to create a view from the store, but using store directly is not possible
/// with `NavigationEnv` because the environment uses closures, and the closures whould have to be generic since
/// `Store` is a generic class with the `Nsp` type parameter.
///
/// Presentation APIs also use `StoreUIContainer`. This makes it easier to replace presentation with push navigation
/// and vice versa.
public protocol StoreUIContainer<Nsp>: Hashable, Identifiable {
    associatedtype Nsp: StoreUINamespace
    var store: Nsp.Store { get }
    init(_ store: Nsp.Store)
}

extension StoreUIContainer {
    @MainActor
    public func makeView() -> some View {
        store.contentView.id(store.id)
    }
    
    @MainActor
    public func makeAnyView() -> AnyView {
        AnyView(makeView())
    }
    
    public var id: Nsp.Store.ID {
        store.id
    }
    
    @MainActor
    public var value: Nsp.Store.ValuePublisher {
        store.value
    }

    @MainActor
    public var anyStore: any AnyStore {
        store
    }

    @MainActor
    public func cancel() {
        store.cancel()
    }
    
    @MainActor
    public func updateNavigationCount() {
        Nsp.updateNavigationCount(store)
    }
}

public struct StoreUI<Nsp: StoreUINamespace>: StoreUIContainer {
    public static func == (lhs: StoreUI<Nsp>, rhs: StoreUI<Nsp>) -> Bool {
        lhs.store === rhs.store
    }
    
    public let store: Nsp.Store

    public init(_ store: Nsp.Store) {
        self.store = store
    }
}

extension StoreUI {
    public init?(_ store: Nsp.Store?) {
        guard let store else { return nil }
        self.init(store)
    }
}

#endif
