//
//  ReducerArchitectureNavigation.swift
//
//  Created by Ilya Belenkiy on 3/28/23.
//

import Foundation

public struct NavigationEnv {
    /// Returns the index of the top component on the stack.
    public let currentIndex: @MainActor () -> Int
    
    /// Pushes the next UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    public let push: @MainActor (any StoreUIContainer & Hashable) -> Int
    
    /// Pushes the next VC on the navigation stack.
    /// Supported only for UIKit navigation.
    /// Returns the index of the pushed component on the navigation stack.
    public let pushVC: @MainActor (any BasicReducerArchitectureVC) -> Int

    /// Replaces the last UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    public let replaceTop: @MainActor (any StoreUIContainer & Hashable) -> Int
    
    /// Pops the navigation stack to the component at `index`.
    public let popTo: @MainActor (_ index: Int) -> Void
}

@MainActor
public extension NavigationEnv {
    func popToRoot() {
        popTo(0)
    }
}

@MainActor
public struct NavigationNode<T: StoreUINamespace> {
    let store: T.Store
    let env: NavigationEnv
    
    public init(_ store: T.Store, _ env: NavigationEnv) {
        self.store = store
        self.env = env
    }
    
    public func then(_ callback: @escaping (T.Store.PublishedValue, Int) async -> Void) async {
        let index = env.push(StoreUI(store))
        await store.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.Store.PublishedValue, Int) async -> Void) async {
        let index = env.replaceTop(StoreUI(store))
        await store.get { value in
            await callback(value, index)
        }
    }
}

@MainActor
public struct NavigationVCNode<VC: BasicReducerArchitectureVC> {
    let config: VC.Configuration
    let env: NavigationEnv
    
    public init(config: VC.Configuration, env: NavigationEnv) {
        self.config = config
        self.env = env
    }
    
    public func then(_ callback: @escaping (VC.Store.PublishedValue, Int) async -> Void) async {
        let vc = VC.make(config)
        let index = env.pushVC(vc)
        await vc.store.get { value in
            await callback(value, index)
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

@available(iOS 16.0, *)
@available(macOS 13.0, *)
public struct NavigationFlow<T: StoreUINamespace>: View {
    let root: T.Store
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
            T.ContentView(store: root)
                .background(
                    ForEach(pathContainer.stack, id: \.id) { storeUI in
                        addNavigation(storeUI)
                    }
                )
        }
        .task {
            let env = NavigationEnv(pathContainer: pathContainer)
            await root.get { value in
                await run(value, env)
            }
        }
    }
}

@available(iOS 16.0, *)
@available(macOS 13.0, *)
@MainActor
public class NavigationPathContainer: ObservableObject {
    public private(set) var stack: [any StoreUIContainer] = []
    private var internalChange = false
    @Published public var path: NavigationPath = .init() {
        willSet {
            guard !internalChange else { return }
            while newValue.count < stack.count {
                stack.removeLast().cancel()
            }
        }
    }
    
    public init() {}
    
    public var currentIndex: Int {
        assert(path.count == stack.count)
        return path.count - 1
    }
    
    public func push(_ newValue: any StoreUIContainer & Hashable) -> Int {
        pushImpl(newValue)
    }
    
    public func pushImpl(_ newValue: some StoreUIContainer & Hashable) -> Int {
        assert(path.count == stack.count)
        internalChange = true
        defer {
            internalChange = false
        }
        
        let store = newValue.store
        stack.append(newValue)
        path.push(.init(store))
        
        return currentIndex
    }
    
    public func replaceTop(newValue: any StoreUIContainer & Hashable) -> Int {
        assert(path.count == stack.count)
        internalChange = true
        defer {
            internalChange = false
        }

        stack.last?.cancel()
        stack.removeLast()
        path.removeLast()
        
        return push(newValue)
    }
    
    public func popTo(index: Int) {
        assert(path.count == stack.count)
        internalChange = true
        defer {
            internalChange = false
        }

        guard index < stack.count else {
            assertionFailure()
            return
        }
        
        let k = path.count - 1 - index
        // cancel order should be in reverse of push order
        var valuesToCancel: [any StoreUIContainer] = []
        for _ in 0..<k {
            valuesToCancel.append(stack.removeLast())
        }
        path.removeLast(k)
        
        for value in valuesToCancel {
            value.cancel()
        }
    }
}

@available(iOS 16.0, *)
@available(macOS 13.0, *)
public extension NavigationPath {
    mutating func push<T: StoreUINamespace>(_ storeUI: StoreUI<T>) {
        append(storeUI)
    }
}

@available(iOS 16.0, *)
@available(macOS 13.0, *)
public struct AddNavigation<T: StoreUINamespace>: ViewModifier {
    let type: T.Type
    
    public func body(content: Content) -> some View {
        content.navigationDestination(for: StoreUI<T>.self) { storeUI in
            storeUI.makeView()
        }
    }
}

@available(iOS 16.0, *)
@available(macOS 13.0, *)
public extension View {
    func addNavigation<T: StoreUINamespace>(_ type: T.Type) -> some View {
        self.modifier(AddNavigation(type: type))
    }
}

@available(iOS 16.0, *)
@available(macOS 13.0, *)
extension NavigationEnv {
    public init(pathContainer: NavigationPathContainer) {
        currentIndex = {
            pathContainer.currentIndex
        }
        
        push = {
            pathContainer.push($0)
        }
        
        pushVC = { _ in
            fatalError("Not supported for SwiftUI")
        }
        
        replaceTop = {
            pathContainer.replaceTop(newValue: $0)
        }
        
        popTo = {
            pathContainer.popTo(index: $0)
        }
    }
}

#endif

#if canImport(UIKit)
import UIKit

extension NavigationEnv {
    static func hostingVC(_ storeUI: some StoreUIContainer, _ container: @escaping () -> UIViewController?) -> UIViewController {
        let vc = HostingController(store: storeUI.store)

        if let appVC = container() {
            appVC.addChild(vc)
            appVC.view.addSubview(vc.view)
            vc.didMove(toParent: appVC)
            vc.view.align(toContainerView: appVC.view)
            return appVC
        }
        else {
            return vc
        }
    }

    public init(
        _ nc: UINavigationController,
        replaceLastWith: @escaping (UINavigationController, UIViewController) -> Void,
        hostingControllerContainer: @escaping () -> UIViewController? = { nil }
    ) {
        currentIndex = {
            nc.viewControllers.count - 1
        }
        
        push = {
            let vc = Self.hostingVC($0, hostingControllerContainer)
            nc.pushViewController(vc, animated: true)
            return nc.viewControllers.count - 1
        }
        
        pushVC = { appVC in
            let vc = ContainerVC(vc: appVC)
            nc.pushViewController(vc, animated: true)
            return nc.viewControllers.count - 1
        }
        
        replaceTop = {
            let vc = Self.hostingVC($0, hostingControllerContainer)
            replaceLastWith(nc, vc)
            return nc.viewControllers.count - 1
        }
        
        popTo = {
            let vc = nc.viewControllers[$0]
            nc.popToViewController(vc, animated: true)
        }
    }
}

#endif
