//
//  AsyncNavigationFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/1/25.
//

import SwiftUI

/// Native SwiftUI navigation doesn't work with nested navigation stacks.
/// This UIKit implementation doesn't have that limitation.
public struct AsyncNavigationUIKitFlow<T: ViewModelUINamespace>: View {
    private struct FlowImpl: UIViewControllerRepresentable {
        let root: T.ViewModel
        let run: (T.PublishedValue, _ env: AsyncNavigationProxy) async -> Void

        func makeUIViewController(context: Context) -> UINavigationController {
            let rootVC = AsyncNavigationUIKitProxy.HostingController<T>(ViewModelUI(root))
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

    public let root: T.ViewModel
    public let run: (T.PublishedValue, _ env: AsyncNavigationProxy) async -> Void

    public init(root: T.ViewModel, run: @escaping (T.PublishedValue, _: AsyncNavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    public var body: some View {
        FlowImpl(root: root, run: run)
            .ignoresSafeArea()
    }
}
