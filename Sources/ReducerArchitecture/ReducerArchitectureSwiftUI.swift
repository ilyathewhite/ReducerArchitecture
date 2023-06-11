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

public protocol StoreContentView: View {
    associatedtype Nsp: StoreNamespace
    typealias Store = Nsp.Store
    var store: Store { get }
    init(store: Store)
}

public protocol StoreUINamespace: StoreNamespace {
    associatedtype ContentView: StoreContentView where ContentView.Nsp == Self
}

public extension StateStore where Nsp: StoreUINamespace {
    var contentView: Nsp.ContentView {
        Nsp.ContentView(store: self)
    }
}

public protocol StoreUIContainer<Nsp>: Hashable, Identifiable {
    associatedtype Nsp: StoreUINamespace
    var store: Nsp.Store { get }
    init(_ store: Nsp.Store)
}

extension StoreUIContainer {
    @MainActor
    public func makeView() -> some View {
        store.contentView
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
    public func cancel() {
        store.cancel()
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

public struct ConnectOnAppear: ViewModifier {
    public let connect: () -> Void

    @State private var isConnected = false

    public func body(content: Content) -> some View {
        content
            .onAppear {
                guard !isConnected else { return }
                connect()
                isConnected = true
            }
    }
}

public extension View {
    func connectOnAppear(connect: @escaping () -> Void) -> some View {
        modifier(ConnectOnAppear(connect: connect))
    }
}

public extension View {
    @MainActor
    func showUI<C: StoreUIContainer>(_ keyPath: KeyPath<Self, C?>) -> Binding<Bool> {
        .init(
            get: {
                guard let storeUI = self[keyPath: keyPath] else {
                    return false
                }
                return !storeUI.store.isCancelled
            },
            set: { show in
                if !show {
                    self[keyPath: keyPath]?.cancel()
                }
            }
        )
    }
}

#endif
