//
//  AsyncNaivgationCustomFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/1/25.
//

import SwiftUI

public struct AsyncNavigationCustomFlow<Nsp: ViewModelUINamespace>: View {
    let root: Nsp.ViewModel
    let run: (Nsp.PublishedValue, _ proxy: AsyncNavigationProxy) async -> Void

    @StateObject private var pathContainer = AsyncNavigationPathContainer()

    public init(root: Nsp.ViewModel, run: @escaping (Nsp.PublishedValue, _: AsyncNavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    public var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                Nsp.ContentView(viewModel: root)
                    .frame(width: proxy.size.width)
                ForEach(pathContainer.stack, id: \.id) { viewModelUI in
                    AnyView(viewModelUI.makeView())
                        .frame(width: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width, alignment: .trailing)
            .onAppear {
                pathContainer.root = ViewModelUI<Nsp>(root)
            }
            .task {
                await root.get { value in
                    await run(value, pathContainer)
                }
            }
        }
    }
}
