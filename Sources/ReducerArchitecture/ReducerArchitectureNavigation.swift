//
//  ReducerArchitectureNavigation.swift
//
//  Created by Ilya Belenkiy on 3/28/23.
//

import Foundation
import Combine
import CombineEx
import os

private enum Placeholder: StoreNamespace {
    typealias PublishedValue = Void
    typealias StoreEnvironment = Never
    typealias MutatingAction = Void
    typealias EffectAction = Never
    struct StoreState {}
}

extension Placeholder {
    @MainActor
    static func store() -> Store {
        .init(identifier, .init(), reducer: reducer())
    }
}

public struct NavigationEnv {
    @MainActor
    struct StoreInfo {
        let timeIndex: Int
        let store: any AnyStore

        static let placeholder = Self.init(timeIndex: -1, store: Placeholder.store())
    }
    
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

    /// Provides the navigation stack top store whenever the navigation stack changes.
    ///
    /// Available only when testing.
    private let currentStorePublisher: CurrentValueSubject<StoreInfo, Never>
    
    public init(
        currentIndex: @escaping () -> Int,
        push: @escaping (any StoreUIContainer & Hashable) -> Int,
        pushVC: @escaping (any BasicReducerArchitectureVC) -> Int,
        replaceTop: @escaping (any StoreUIContainer & Hashable) -> Int,
        popTo: @escaping (_: Int) -> Void
    ) {
        self.init(
            currentIndex: currentIndex,
            push: push,
            pushVC: pushVC,
            replaceTop: replaceTop,
            popTo: popTo,
            currentStorePublisher: .init(.placeholder)
        )
    }

    init(currentIndex: @escaping () -> Int,
         push: @escaping (any StoreUIContainer & Hashable) -> Int,
         pushVC: @escaping (any BasicReducerArchitectureVC) -> Int,
         replaceTop: @escaping (any StoreUIContainer & Hashable) -> Int,
         popTo: @escaping (_: Int) -> Void,
         currentStorePublisher: CurrentValueSubject<StoreInfo, Never>
    ) {
        self.currentIndex = currentIndex
        self.push = push
        self.pushVC = pushVC
        self.replaceTop = replaceTop
        self.popTo = popTo
        self.currentStorePublisher = currentStorePublisher
    }
}

@MainActor
public extension NavigationEnv {
    func pop() {
        popTo(currentIndex() - 1)
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

    public func then(_ callback: @escaping (T.Store.PublishedValue, Int) async throws -> Void) async throws {
        let index = env.push(StoreUI(store))
        try await store.get { value in
            try await callback(value, index)
        }
    }

    public func then(_ callback: @escaping (T.Store.PublishedValue, Int) async -> Void) async {
        let index = env.push(StoreUI(store))
        await store.get { value in
            await callback(value, index)
        }
    }

    public func thenReplacingTop(_ callback: @escaping (T.Store.PublishedValue, Int) async throws -> Void) async throws {
        let index = env.replaceTop(StoreUI(store))
        try await store.get { value in
            try await callback(value, index)
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
    
    public func then(_ callback: @escaping (VC.Store.PublishedValue, Int) async throws -> Void) async throws {
        let vc = VC.make(config)
        let index = env.pushVC(vc)
        try await vc.store.get { value in
            try await callback(value, index)
        }
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

/// Same as NavigationFlow, but uses UINavigationController for navigation.
///
/// This is a workaround for nested navigation stacks that don't seem to be supported in SwiftUI right now.
public struct UIKitNavigationFlow<T: StoreUINamespace>: UIViewControllerRepresentable {
    public let root: T.Store
    public let run: (T.PublishedValue, _ env: NavigationEnv) async -> Void
    
    public init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationEnv) async -> Void) {
        self.root = root
        self.run = run
    }

    public init(root: T.Store) {
        self.root = root
        self.run = { _, _ in }
    }

    public func makeUIViewController(context: Context) -> UINavigationController {
        let nc = UINavigationController()
        Task {
            let env = NavigationEnv(nc, replaceLastWith: { _, _  in })
            await root.get { value in
                await run(value, env)
            }
        }
        
        let rootView = T.ContentView(store: root)
        let rootVC = UIHostingController(rootView: rootView)
        nc.viewControllers = [rootVC]
        return nc
    }
    
    public func updateUIViewController(_ nc: UINavigationController, context: Context) {
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

        guard -1 <= index, index < stack.count else {
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
    @MainActor
    public init(pathContainer: NavigationPathContainer) {
        self.init(
            currentIndex: {
                pathContainer.currentIndex
            },
            push: {
                pathContainer.push($0)
            },
            pushVC: { _ in
                fatalError("Not supported for SwiftUI")
            },
            replaceTop: {
                pathContainer.replaceTop(newValue: $0)
            },
            popTo: {
                pathContainer.popTo(index: $0)
            }
        )
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
    
    static func getStore(_ storeUI: some StoreUIContainer) -> any AnyStore {
        storeUI.store
    }
    
    static func getStore(_ container: some BasicReducerArchitectureVC) -> any AnyStore {
        container.store
    }

    @MainActor
    public init(
        _ nc: UINavigationController,
        replaceLastWith: @escaping (UINavigationController, UIViewController) -> Void,
        hostingControllerContainer: @escaping () -> UIViewController? = { nil }
    ) {
        self.init(
            currentIndex: {
                nc.viewControllers.count - 1
            },
            push: {
                let vc = Self.hostingVC($0, hostingControllerContainer)
                nc.pushViewController(vc, animated: true)
                return nc.viewControllers.count - 1
            },
            pushVC: {
                let vc = ContainerVC(vc: $0)
                nc.pushViewController(vc, animated: true)
                return nc.viewControllers.count - 1
            },
            replaceTop: {
                let vc = Self.hostingVC($0, hostingControllerContainer)
                replaceLastWith(nc, vc)
                return nc.viewControllers.count - 1
            },
            popTo: {
                let vc = nc.viewControllers[$0]
                nc.popToViewController(vc, animated: true)
            }
        )
    }
}

#endif

extension AnyStore {
    public func publishOnRequest(_ value: PublishedValue) async {
        while !hasRequest {
            await Task.yield()
        }
        publish(value)
    }
}

extension NavigationEnv {
    enum NavigationTestNode {
        case storeUI(any StoreUIContainer)
        case vc(any BasicReducerArchitectureVC)
        
        var store: (any AnyStore)? {
            switch self {
            case .storeUI(let storeUI):
                return NavigationEnv.getStore(storeUI)
            case .vc(let vc):
                return NavigationEnv.getStore(vc)
            }
        }
    }
    
    enum CurrentStoreError: Error {
        case typeMismatch
    }

    /// Returns the store of a particular type for a given time index.
    ///
    /// Used only for testing.
    @MainActor
    public func getStore<T: StoreNamespace>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T.Store {
        let value = await currentStorePublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let store = value?.store as? T.Store else {
            throw CurrentStoreError.typeMismatch
        }
        timeIndex += 1
        return store
    }

    /// Returns the store of a particular type for a given time index.
    ///
    /// Used only for testing.
    @MainActor
    public func getStore<T: AnyStore>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T {
        let value = await currentStorePublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let store = value?.store as? T else {
            throw CurrentStoreError.typeMismatch
        }
        timeIndex += 1
        return store
    }

    @MainActor
    /// Used only for testing.
    public func backAction() {
        return pop()
    }
    
    @MainActor
    public static func testEnv() -> NavigationEnv {
        let currentStorePublisher: CurrentValueSubject<StoreInfo, Never> = .init(StoreInfo.placeholder)
        var stack: [NavigationTestNode] = []
        
        func updateCurrentStore() {
            guard let store = stack.last?.store else {
                assertionFailure()
                return
            }
            let timeIndex = currentStorePublisher.value.timeIndex + 1
            currentStorePublisher.send(.init(timeIndex: timeIndex, store: store))
        }
        
        return .init(
            currentIndex: {
                stack.count - 1
            },
            push: {
                stack.append(.storeUI($0))
                updateCurrentStore()
                return stack.count - 1
            },
            pushVC: {
                stack.append(.vc($0))
                updateCurrentStore()
                return stack.count - 1
            },
            replaceTop: {
                guard let last = stack.last else {
                    assertionFailure()
                    return 0
                }
                last.store?.cancel()
                
                stack[stack.count - 1] = .storeUI($0)
                updateCurrentStore()
                return stack.count - 1
            },
            popTo: { index in
                guard -1 <= index, index < stack.count else {
                    assertionFailure()
                    return
                }
                let k = stack.count - 1 - index
                // cancel order should be in reverse of push order
                var valuesToCancel: [any AnyStore] = []
                for _ in 0..<k {
                    guard let store = stack.removeLast().store else {
                        assertionFailure()
                        continue
                    }
                    valuesToCancel.append(store)
                }
                
                for value in valuesToCancel {
                    value.cancel()
                }

                updateCurrentStore()
            },
            currentStorePublisher: currentStorePublisher
        )
    }
}
