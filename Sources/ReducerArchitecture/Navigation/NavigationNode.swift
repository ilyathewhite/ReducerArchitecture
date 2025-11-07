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
    let env: NavigationEnv

    public init(_ store: T.Store, _ env: NavigationEnv) {
        self.store = store
        self.env = env
    }

    public func then(_ callback: @escaping (T.Store.PublishedValue, Int) async throws -> Void) async throws {
        let index = env.push(StoreUI(store))
        try await store.get { value in
            try await callback(value, index)
        }
    }

    public func then(_ callback: @escaping (T.Store.PublishedValue, Int) async -> Void) async {
        let index = env.push(StoreUI(store))
        await store.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.Store.PublishedValue, Int) async throws -> Void) async throws {
        let index = env.replaceTop(StoreUI(store))
        try await store.get { value in
            try await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.Store.PublishedValue, Int) async -> Void) async {
        let index = env.replaceTop(StoreUI(store))
        await store.get { value in
            await callback(value, index)
        }
    }
}
