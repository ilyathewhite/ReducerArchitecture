//
//  AsyncNavigationNode.swift
//
//  Created by Codex.
//

import SwiftUI

public struct ViewModelUI<T: ViewModelUINamespace> {
    let viewModel: T.ViewModel

    public init(_ viewModel: T.ViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func makeView() -> T.ContentView {
        T.ContentView(viewModel: viewModel)
    }
}

@MainActor
public struct AsyncNavigationNode<T: ViewModelUINamespace> {
    @State private var viewModel: T.ViewModel
    let navigationProxy: AsyncNavigationProxy

    public init(_ viewModel: T.ViewModel, _ navigationProxy: AsyncNavigationProxy) {
        self._viewModel = State(initialValue: viewModel)
        self.navigationProxy = navigationProxy
    }

    public func then(_ callback: @escaping (T.PublishedValue, Int) async throws -> Void) async throws {
        let index = navigationProxy.push(ViewModelUI<T>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func then(_ callback: @escaping (T.PublishedValue, Int) async -> Void) async {
        let index = navigationProxy.push(ViewModelUI<T>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.PublishedValue, Int) async throws -> Void) async throws {
        let index = navigationProxy.replaceTop(with: ViewModelUI<T>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.PublishedValue, Int) async -> Void) async {
        let index = navigationProxy.replaceTop(with: ViewModelUI<T>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }
}
