//
//  ViewModelNamespaces.swift
//
//  Created by Codex.
//

import SwiftUI

public protocol ViewModelNamespace {
    associatedtype ViewModel: AnyViewModel
    typealias PublishedValue = ViewModel.PublishedValue
}

@MainActor
public protocol ViewModelContentView: View {
    associatedtype Nsp: ViewModelNamespace
    typealias ViewModel = Nsp.ViewModel
    var viewModel: ViewModel { get }
    init(viewModel: ViewModel)
}

@MainActor
public protocol ViewModelUINamespace: ViewModelNamespace {
    associatedtype ContentView: ViewModelContentView where ContentView.Nsp == Self
    static func updateNavigationCount(_ viewModel: ViewModel)
}

public extension ViewModelUINamespace {
    static func updateNavigationCount(_ viewModel: ViewModel) {}
}
