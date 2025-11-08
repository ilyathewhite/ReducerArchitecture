//
//  NavigationUIKitFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

#if os(iOS)
import SwiftUI
import UIKit

/// Same as NavigationFlow, but uses UINavigationController for navigation.
///
/// This is a workaround for nested navigation stacks that don't seem to be supported in SwiftUI right now.
public struct UIKitNavigationFlow<T: StoreUINamespace>: View {
    public let root: T.Store
    public let run: (T.PublishedValue, _ proxy: NavigationProxy) async -> Void

    public init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    public var body: some View {
        UIKitNavigationFlowImpl(root: root, run: run)
            .ignoresSafeArea()
    }
}

// Cannot use this struct directly due to limitations related to safe area.
struct UIKitNavigationFlowImpl<T: StoreUINamespace>: UIViewControllerRepresentable {
    let root: T.Store
    let run: (T.PublishedValue, _ env: NavigationProxy) async -> Void

    init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    init(root: T.Store) {
        self.root = root
        self.run = { _, _ in }
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let rootVC = HostingController(store: root)
        let nc = UINavigationController(rootViewController: rootVC)
        Task {
            let navigationProxy = NavigationUIKitProxy(nc)
            await root.get { value in
                await run(value, navigationProxy)
            }
        }

        return nc
    }

    func updateUIViewController(_ nc: UINavigationController, context: Context) {
    }
}

#endif
