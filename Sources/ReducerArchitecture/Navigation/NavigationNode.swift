//
//  NavigationNode.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/3/25.
//

import SwiftUI

@MainActor
public struct NavigationNode<T: StoreUINamespace> {
    @State private var store: T.Store
    let proxy: NavigationProxy

    public init(_ store: T.Store, _ proxy: NavigationProxy) {
        self.store = store
        self.proxy = proxy
    }

    public func then(_ callback: @escaping (T.Store.PublishedValue, Int) async throws -> Void) async throws {
        let index = proxy.push(StoreUI(store))
        try await store.get { value in
            try await callback(value, index)
        }
    }

    public func then(_ callback: @escaping (T.Store.PublishedValue, Int) async -> Void) async {
        let index = proxy.push(StoreUI(store))
        await store.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.Store.PublishedValue, Int) async throws -> Void) async throws {
        let index = proxy.replaceTop(with: StoreUI(store))
        try await store.get { value in
            try await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.Store.PublishedValue, Int) async -> Void) async {
        let index = proxy.replaceTop(with: StoreUI(store))
        await store.get { value in
            await callback(value, index)
        }
    }
}
