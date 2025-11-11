//
//  BasicViewModelUI.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/9/25.
//

import SwiftUI

public protocol ViewModelContentView: View {
    associatedtype ViewMdodel: BasicViewModel
    init(_ viewModel: ViewMdodel)
}

public protocol ViewModelUINamespace {
    associatedtype ContentView: ViewModelContentView
    associatedtype ViewModel: BasicViewModel where ViewModel == ContentView.ViewMdodel
}

@MainActor
public protocol ViewModelUIContainer: Hashable, Identifiable {
    associatedtype Nsp: ViewModelUINamespace
    var viewModel: Nsp.ViewModel { get }
    init(_ store: Nsp.ViewModel)
}

extension ViewModelUIContainer {
    public func makeView() -> some View {
        Nsp.ContentView(viewModel).id(viewModel.id)
    }

    @MainActor
    public func makeAnyView() -> AnyView {
        AnyView(makeView())
    }

    @MainActor
    public var id: UUID {
        viewModel.id
    }

    @MainActor
    public var value: Nsp.ViewModel.ValuePublisher {
        viewModel.value
    }

    @MainActor
    public var anyViewModel: any BasicViewModel {
        viewModel
    }

    @MainActor
    public func cancel() {
        viewModel.cancel()
    }
}

public struct ViewModelUI<Nsp: ViewModelUINamespace>: ViewModelUIContainer {
    public let viewModel: Nsp.ViewModel

    public static func == (lhs: ViewModelUI, rhs: ViewModelUI) -> Bool {
        lhs.viewModel === rhs.viewModel
    }

    public init(_ viewModel: Nsp.ViewModel) {
        self.viewModel = viewModel
    }

    public init?(_ viewModel: Nsp.ViewModel?) {
        guard let viewModel else { return nil }
        self.init(viewModel)
    }
}
