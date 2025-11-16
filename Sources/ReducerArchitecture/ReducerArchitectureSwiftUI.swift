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
public protocol StoreContentView: ViewModelContentView where ViewModel == Store {
    associatedtype Nsp: StoreNamespace
    typealias Store = Nsp.Store    
    var store: Store { get }
}

public protocol StoreUINamespace: StoreNamespace, ViewModelUINamespace
where ContentView: StoreContentView, ContentView.Nsp == Self, ViewModel == Store {
    static func updateNavigationCount(_ store: Store) -> Void
}

public extension StoreUINamespace {
    static func updateNavigationCount(_ store: Store) -> Void {}
}

public extension StateStore where Nsp: StoreUINamespace {
    var contentView: Nsp.ContentView {
        Nsp.ContentView(self)
    }
}

public typealias StoreUI<Nsp> = ViewModelUI<Nsp> where Nsp: StoreUINamespace

#endif
