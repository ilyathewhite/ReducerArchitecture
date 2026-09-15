//  StateStore+SwiftUI.swift
//  Created by Ilya Belenkiy on 8/28/21.

#if canImport(SwiftUI)
import SwiftUI

public extension StateStore {
    /// Does not retain the store. After release, reads return the last observed value and writes are ignored.
    func binding<Value>(
        _ keyPath: KeyPath<State, Value>,
        _ action: @escaping (Value) -> MutatingAction,
        animation: Animation? = nil,
        file: String = #fileID, line: Int = #line
    )
    ->
    Binding<Value> where Value: Equatable
    {
        var lastValue = state[keyPath: keyPath]
        return Binding(
            get: { [weak self] in
                if let self { lastValue = self.state[keyPath: keyPath] }
                return lastValue
            },
            set: { [weak self] value in
                guard let self else { return }
                if self.state[keyPath: keyPath] != value {
                    if let animation = animation {
                        self.send(.mutating(action(value), animated: true, animation))
                    }
                    else {
                        self.send(.mutating(action(value)), file: file, line: line)
                    }
                }
                lastValue = self.state[keyPath: keyPath]
            }
        )
    }

    /// Does not retain the store. After release, reads return the last observed value.
    func readOnlyBinding<Value>(_ keyPath: KeyPath<State, Value>) -> Binding<Value> {
        var lastValue = state[keyPath: keyPath]
        return Binding(
            get: { [weak self] in
                if let self { lastValue = self.state[keyPath: keyPath] }
                return lastValue
            },
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
    @MainActor
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
