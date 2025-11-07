//
//  NavigationSwiftUIFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

import SwiftUI

public struct NavigationFlow<T: StoreUINamespace>: View {
    @State private var root: T.Store
    let run: (T.PublishedValue, _ env: NavigationEnv) async -> Void

    @StateObject private var pathContainer = NavigationPathContainer()

    public init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationEnv) async -> Void) {
        self.root = root
        self.run = run
    }

    func addNavigation(_ storeUI: some StoreUIContainer) -> AnyView {
        AnyView(
            EmptyView()
                .addNavigation(type(of: storeUI).Nsp.self)
        )
    }

    public var body: some View {
        NavigationStack(path: $pathContainer.path) {
            root.contentView
                .background(
                    ForEach(pathContainer.stack, id: \.id) { storeUI in
                        addNavigation(storeUI)
                    }
                )
        }
        .onAppear {
            pathContainer.root = StoreUI(root)
        }
        .environment(\.backAction, { pathContainer.pop() })
        .preference(key: NavigationPathStackKey.self, value: .init(value: pathContainer.stack))
        .task {
            let env = NavigationEnv(pathContainer: pathContainer)
            await root.get { value in
                await run(value, env)
            }
        }
    }
}

public struct AddNavigation<T: StoreUINamespace>: ViewModifier {
    let type: T.Type

    public func body(content: Content) -> some View {
        content.navigationDestination(for: StoreUI<T>.self) { storeUI in
            storeUI.makeView()
        }
    }
}

public extension View {
    func addNavigation<T: StoreUINamespace>(_ type: T.Type) -> some View {
        self.modifier(AddNavigation(type: type))
    }
}
