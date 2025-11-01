//
//  AsyncNavigationNode.swift
//
//  Created by Codex.
//

import SwiftUI

public protocol ViewModelUIContainer<Nsp>: Hashable, Identifiable {
    associatedtype Nsp: ViewModelUINamespace
    var viewModel: Nsp.ViewModel { get }
    init(_ viewModel: Nsp.ViewModel)
}

extension ViewModelUIContainer {
    @MainActor
    public func makeView() -> some View {
        Nsp.ContentView(viewModel: viewModel).id(viewModel.id)
    }

    public var id: UUID {
        viewModel.id
    }
}

public struct ViewModelUI<Nsp: ViewModelUINamespace>: ViewModelUIContainer {
    public let viewModel: Nsp.ViewModel

    public init(_ viewModel: Nsp.ViewModel) {
        self.viewModel = viewModel
    }

    @MainActor
    func makeView() -> Nsp.ContentView {
        Nsp.ContentView(viewModel: viewModel)
    }
}

@MainActor
public struct AsyncNavigationNode<Nsp: ViewModelUINamespace> {
    @State private var viewModel: Nsp.ViewModel
    let navigationProxy: AsyncNavigationProxy

    public init(_ viewModel: Nsp.ViewModel, _ navigationProxy: AsyncNavigationProxy) {
        self._viewModel = State(initialValue: viewModel)
        self.navigationProxy = navigationProxy
    }

    public func then(_ callback: @escaping (Nsp.PublishedValue, Int) async throws -> Void) async throws {
        let index = navigationProxy.push(ViewModelUI<Nsp>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func then(_ callback: @escaping (Nsp.PublishedValue, Int) async -> Void) async {
        let index = navigationProxy.push(ViewModelUI<Nsp>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (Nsp.PublishedValue, Int) async throws -> Void) async throws {
        let index = navigationProxy.replaceTop(with: ViewModelUI<Nsp>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (Nsp.PublishedValue, Int) async -> Void) async {
        let index = navigationProxy.replaceTop(with: ViewModelUI<Nsp>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }
}
