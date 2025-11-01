//
//  AsyncNavigationFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/1/25.
//

import SwiftUI

/// Native SwiftUI navigation doesn't work with nested navigation stacks.
/// This UIKit implementation doesn't have that limitation.
public struct AsyncNavigationUIKitFlow<Nsp: ViewModelUINamespace>: View {
    private struct FlowImpl: UIViewControllerRepresentable {
        let root: Nsp.ViewModel
        let run: (Nsp.PublishedValue, _ env: AsyncNavigationProxy) async -> Void

        func makeUIViewController(context: Context) -> UINavigationController {
            let rootVC = AsyncNavigationUIKitProxy.HostingController<Nsp>(ViewModelUI(root))
            let nc = UINavigationController(rootViewController: rootVC)
            Task {
                let navigationProxy = AsyncNavigationUIKitProxy(nc)
                await root.get { value in
                    await run(value, navigationProxy)
                }
            }

            return nc
        }

        func updateUIViewController(_ nc: UINavigationController, context: Context) {
        }
    }

    public let root: Nsp.ViewModel
    public let run: (Nsp.PublishedValue, _ env: AsyncNavigationProxy) async -> Void

    public init(root: Nsp.ViewModel, run: @escaping (Nsp.PublishedValue, _: AsyncNavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    public var body: some View {
        FlowImpl(root: root, run: run)
            .ignoresSafeArea()
    }
}
