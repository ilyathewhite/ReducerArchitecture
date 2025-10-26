//
//  ViewModelUIContainer.swift
//
//  Created by Codex.
//

import Combine
import CombineEx
import SwiftUI

public protocol ViewModelUIContainer<Nsp>: Hashable, Identifiable {
    associatedtype Nsp: ViewModelUINamespace
    var viewModel: Nsp.ViewModel { get }
    init(_ viewModel: Nsp.ViewModel)
}

public extension ViewModelUIContainer {
    @MainActor
    func makeView() -> some View {
        Nsp.ContentView(viewModel: viewModel)
            .id(viewModel.id)
    }

    @MainActor
    func makeAnyView() -> AnyView {
        AnyView(makeView())
    }

    nonisolated var id: Nsp.ViewModel.ID {
        viewModel.id
    }

    @MainActor
    var value: AnyPublisher<Nsp.PublishedValue, Cancel> {
        viewModel.value
    }

    @MainActor
    func cancel() {
        viewModel.cancel()
    }

    @MainActor
    func updateNavigationCount() {
        Nsp.updateNavigationCount(viewModel)
    }
}

public struct ViewModelUI<Nsp: ViewModelUINamespace>: ViewModelUIContainer {
    public static func == (lhs: ViewModelUI<Nsp>, rhs: ViewModelUI<Nsp>) -> Bool {
        lhs.viewModel === rhs.viewModel
    }

    public let viewModel: Nsp.ViewModel

    public init(_ viewModel: Nsp.ViewModel) {
        self.viewModel = viewModel
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(viewModel.id)
    }
}

public extension ViewModelUI {
    init?(_ viewModel: Nsp.ViewModel?) {
        guard let viewModel else { return nil }
        self.init(viewModel)
    }
}
