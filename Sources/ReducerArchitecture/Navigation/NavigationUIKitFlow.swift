//
//  NavigationUIKitFlow.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

#if os(iOS)
import SwiftUI
import UIKit
import Combine
import CombineEx

public class HostingController<T: ViewModelUIContainer>: UIHostingController<T.Nsp.ContentView> {
    public let viewModel: T.Nsp.ViewModel

    public init(viewModel: T.Nsp.ViewModel) {
        self.viewModel = viewModel
        super.init(rootView: T.Nsp.ContentView(viewModel))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func didMove(toParent parent: UIViewController?) {
        if parent == nil {
            viewModel.cancel()
        }
    }
}

/// Same as NavigationFlow, but uses UINavigationController for navigation.
///
/// This is a workaround for nested navigation stacks that don't seem to be supported in SwiftUI right now.
public struct UIKitNavigationFlow<Nsp: ViewModelUINamespace>: View {
    public typealias RootViewModel = Nsp.ViewModel
    public let root: RootViewModel
    public let run: (RootViewModel.PublishedValue, _ proxy: NavigationProxy) async -> Void

    public init(root: RootViewModel, run: @escaping (RootViewModel.PublishedValue, _: NavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    public var body: some View {
        UIKitNavigationFlowImpl<Nsp>(root: root, run: run)
            .ignoresSafeArea()
    }
}

// Cannot use this struct directly due to limitations related to safe area.
struct UIKitNavigationFlowImpl<Nsp: ViewModelUINamespace>: UIViewControllerRepresentable {
    public typealias RootViewModel = Nsp.ViewModel
    let root: RootViewModel
    let run: (RootViewModel.PublishedValue, _ env: NavigationProxy) async -> Void

    init(root: RootViewModel, run: @escaping (RootViewModel.PublishedValue, _: NavigationProxy) async -> Void) {
        self.root = root
        self.run = run
    }

    init(root: RootViewModel) {
        self.root = root
        self.run = { _, _ in }
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let rootVC = HostingController<ViewModelUI<Nsp>>(viewModel: root)
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

