//
//  AsyncNavigationNode.swift
//
//  Created by Codex.
//

import SwiftUI

@MainActor
public struct AsyncNavigationNode<T: ViewModelUINamespace> {
    @State private var viewModel: T.ViewModel
    let env: AsyncNavigationEnv

    public init(_ viewModel: T.ViewModel, _ env: AsyncNavigationEnv) {
        self._viewModel = State(initialValue: viewModel)
        self.env = env
    }

    public func then(_ callback: @escaping (T.PublishedValue, Int) async throws -> Void) async throws {
        let index = env.push(ViewModelUI<T>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func then(_ callback: @escaping (T.PublishedValue, Int) async -> Void) async {
        let index = env.push(ViewModelUI<T>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.PublishedValue, Int) async throws -> Void) async throws {
        let index = env.replaceTop(ViewModelUI<T>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.PublishedValue, Int) async -> Void) async {
        let index = env.replaceTop(ViewModelUI<T>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }
}
