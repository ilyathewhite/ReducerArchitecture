//
//  NavigationSwiftUIFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

import SwiftUI

public struct NavigationFlow<Nsp: ViewModelUINamespace>: View {
    public typealias RootViewModel = Nsp.ViewModel
    @State private var root: RootViewModel
    let run: (RootViewModel.PublishedValue, _ proxy: NavigationProxy) async -> Void

    @StateObject private var pathContainer = NavigationPathContainer()

    public init(root: RootViewModel, run: @escaping (RootViewModel.PublishedValue, _: NavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    func addNavigation(_ viewModelUI: some ViewModelUIContainer) -> AnyView {
        AnyView(
            EmptyView()
                .addNavigation(type(of: viewModelUI).Nsp.self)
        )
    }

    public var body: some View {
        NavigationStack(path: $pathContainer.path) {
            Nsp.ContentView(root)
                .background(
                    ForEach(pathContainer.stack, id: \.id) { viewModelUI in
                        addNavigation(viewModelUI)
                    }
                )
        }
        .onAppear {
            pathContainer.root = ViewModelUI<Nsp>(root)
        }
        .environment(\.backAction, { pathContainer.pop() })
        .preference(key: NavigationPathStackKey.self, value: .init(value: pathContainer.stack))
        .task {
            await root.get { value in
                await run(value, pathContainer)
            }
        }
    }
}

public struct AddNavigation<Nsp: ViewModelUINamespace>: ViewModifier {
    let type: Nsp.Type

    public func body(content: Content) -> some View {
        content.navigationDestination(for: ViewModelUI<Nsp>.self) { viewModelUI in
            viewModelUI.makeView()
        }
    }
}

public extension View {
    func addNavigation<Nsp: ViewModelUINamespace>(_ type: Nsp.Type) -> some View {
        self.modifier(AddNavigation(type: type))
    }
}
