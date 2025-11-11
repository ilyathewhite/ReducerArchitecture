//
//  NavigationNode.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/3/25.
//

import SwiftUI

@MainActor
public struct NavigationNode<Nsp: ViewModelUINamespace> {
    @State private var viewModel: Nsp.ViewModel
    let proxy: NavigationProxy

    public init(_ viewModel: Nsp.ViewModel, _ proxy: NavigationProxy) {
        self.viewModel = viewModel
        self.proxy = proxy
    }

    public func then(_ callback: @escaping (Nsp.ViewModel.PublishedValue, Int) async throws -> Void) async throws {
        let index = proxy.push(ViewModelUI<Nsp>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func then(_ callback: @escaping (Nsp.ViewModel.PublishedValue, Int) async -> Void) async {
        let index = proxy.push(ViewModelUI<Nsp>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (Nsp.ViewModel.PublishedValue, Int) async throws -> Void) async throws {
        let index = proxy.replaceTop(with: ViewModelUI<Nsp>(viewModel))
        try await viewModel.get { value in
            try await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (Nsp.ViewModel.PublishedValue, Int) async -> Void) async {
        let index = proxy.replaceTop(with: ViewModelUI<Nsp>(viewModel))
        await viewModel.get { value in
            await callback(value, index)
        }
    }
}
