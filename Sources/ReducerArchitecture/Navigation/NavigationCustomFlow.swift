//
//  NavigationCustomFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/5/25.
//

import SwiftUI

#if os(macOS)

public struct CustomNavigationFlow<T: StoreUINamespace>: View {
    let root: T.Store
    let run: (T.PublishedValue, _ proxy: NavigationProxy) async -> Void

    @StateObject private var pathContainer = NavigationPathContainer()

    public init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                root.contentView
                    .frame(width: proxy.size.width)
                ForEach(pathContainer.stack, id: \.id) { storeUI in
                    storeUI.makeAnyView()
                        .frame(width: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, alignment: .trailing)
            .onAppear {
                pathContainer.root = StoreUI(root)
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
}

#endif
