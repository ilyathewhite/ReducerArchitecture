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
    associatedtype StoreWrapper: StoreNamespace
    typealias Store = StoreWrapper.Store
    var store: Store { get }
    init(store: Store)
}

public protocol StoreUIWrapper: StoreNamespace {
    associatedtype ContentView: StoreContentView where ContentView.StoreWrapper == Self
}

public protocol StoreUIContainer<UIWrapper> {
    associatedtype UIWrapper: StoreUIWrapper
    var store: UIWrapper.Store { get }
    init(_ store: UIWrapper.Store)
}

extension StoreUIContainer {
    public func makeView() -> some View {
        UIWrapper.ContentView(store: store)
    }
    
    public func makeAnyView() -> AnyView {
        AnyView(makeView())
    }

    @MainActor
    public var value: UIWrapper.Store.ValuePublisher {
        store.value
    }
    
    @MainActor
    public func cancel() {
        store.cancel()
    }
}

public struct StoreUI<UIWrapper: StoreUIWrapper>: StoreUIContainer {
    public let store: UIWrapper.Store

    public init(_ store: UIWrapper.Store) {
        self.store = store
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
            get: { self[keyPath: keyPath] != nil },
            set: { show in
                if !show {
                    self[keyPath: keyPath]?.cancel()
                }
            }
        )
    }
}

#endif
