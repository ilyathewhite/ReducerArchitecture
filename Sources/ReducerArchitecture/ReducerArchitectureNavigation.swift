//
//  ReducerArchitectureNavigation.swift
//
//  Created by Ilya Belenkiy on 3/28/23.
//

import Foundation
import Combine
import CombineEx
import os

private enum NavigationEnvPlaceholder: StoreNamespace {
    typealias PublishedValue = Void
    typealias StoreEnvironment = Never
    typealias MutatingAction = Void
    typealias EffectAction = Never
    struct StoreState {}
}

extension NavigationEnvPlaceholder {
    @MainActor
    static func store() -> Store {
        .init(.init(), reducer: reducer())
    }
}

public struct NavigationEnv {
    @MainActor
    struct StoreInfo {
        let timeIndex: Int
        let store: any AnyStore

        static let placeholder = Self.init(timeIndex: -1, store: NavigationEnvPlaceholder.store())
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
    @State private var store: T.Store
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

#if canImport(UIKit)
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
#endif

private struct BackActionKey: EnvironmentKey {
    static let defaultValue: (() -> ())? = nil
}

public extension EnvironmentValues {
    var backAction: (() -> ())? {
        get { self[BackActionKey.self] }
        set { self[BackActionKey.self] = newValue }
    }
}

public struct NavigationPathStack: Equatable {
    public let value: [any StoreUIContainer]
    
    public static func ==(lhs: NavigationPathStack, rhs: NavigationPathStack) -> Bool {
        lhs.value.map { $0.id } == rhs.value.map { $0.id }
    }
}

public struct NavigationPathStackKey: PreferenceKey {
    public static let defaultValue: NavigationPathStack? = nil
    
    public static func reduce(value: inout NavigationPathStack?, nextValue: () -> NavigationPathStack?) {
        value = value ?? nextValue()
    }
}

#if canImport(SwiftUI)
import SwiftUI

@available(iOS 16.0, *)
@available(macOS 13.0, *)
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

#if os(macOS)

public struct CustomNavigationFlow<T: StoreUINamespace>: View {
    let root: T.Store
    let run: (T.PublishedValue, _ env: NavigationEnv) async -> Void
    
    @StateObject private var pathContainer = NavigationPathContainer()
    
    public init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationEnv) async -> Void) {
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
                let env = NavigationEnv(pathContainer: pathContainer)
                await root.get { value in
                    await run(value, env)
                }
            }
        }
    }
}

#endif

#if os(iOS)

/// Same as NavigationFlow, but uses UINavigationController for navigation.
///
/// This is a workaround for nested navigation stacks that don't seem to be supported in SwiftUI right now.
public struct UIKitNavigationFlow<T: StoreUINamespace>: View {
    public let root: T.Store
    public let run: (T.PublishedValue, _ env: NavigationEnv) async -> Void
    
    public init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationEnv) async -> Void) {
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
    let run: (T.PublishedValue, _ env: NavigationEnv) async -> Void
    
    init(root: T.Store, run: @escaping (T.PublishedValue, _: NavigationEnv) async -> Void) {
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
            let env = NavigationEnv(nc, replaceLastWith: { _, _  in })
            await root.get { value in
                await run(value, env)
            }
        }
        
        return nc
    }
    
    func updateUIViewController(_ nc: UINavigationController, context: Context) {
    }
}

#endif

@available(iOS 16.0, *)
@available(macOS 13.0, *)
@MainActor
public class NavigationPathContainer: ObservableObject {
    var root: (any StoreUIContainer)?
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
        defer { newValue.updateNavigationCount() }
        return pushImpl(newValue)
    }
    
    public func pop() {
        popTo(index: currentIndex - 1)
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
            if let last = stack.last {
                last.updateNavigationCount()
            }
            else {
                root?.updateNavigationCount()
            }
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

extension NavigationEnv {
    static func getStore(_ storeUI: some StoreUIContainer) -> any AnyStore {
        storeUI.store
    }    
    
    static func getStore(_ container: some BasicReducerArchitectureVC) -> any AnyStore {
        container.store
    }
}

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

// Sheet or Window

#if os(macOS)

private struct DismissModalWindowKey: EnvironmentKey {
    static let defaultValue: (() -> ())? = nil
}

public extension EnvironmentValues {
    var dismissModalWindow: (() -> ())? {
        get { self[DismissModalWindowKey.self] }
        set { self[DismissModalWindowKey.self] = newValue }
    }
}

#endif

public struct FullScreenOrWindow<C: StoreUIContainer, V: View>: ViewModifier {
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var id: UUID?
#endif
    
    let isPresented: Binding<Bool>
    let storeUI: C?
    let isModal: Bool
    let presentedContent: () -> V?
    
#if os(macOS)
    var canDismissModalWindow: Bool {
        isModal && isPresented.wrappedValue
    }
#endif
    
    public init(isPresented: Binding<Bool>, storeUI: C?, isModal: Bool, content: @escaping () -> V?) {
        self.isPresented = isPresented
        self.storeUI = storeUI
        self.isModal = isModal
        self.presentedContent = content
    }

    public func body(content: Content) -> some View {
#if os(iOS)
        content.fullScreenCover(isPresented: isPresented, content: presentedContent)
#else
        content.onChange(of: storeUI) { storeUI in
            if let storeUI {
                id = storeUI.id
                StoreUIContainers.add(storeUI)
                openWindow(id: C.Nsp.Store.storeDefaultKey, value: storeUI.id)
            }
            else {
                if let id {
                    StoreUIContainers.remove(id: id)
                }
            }
        }
        .overlay {
            if isModal, id != nil, let storeUI, !storeUI.store.isCancelled {
                Color.primary.opacity(0.1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        id = nil
                        storeUI.cancel()
                    }
            }
        }
        .onDisappear {
            id = nil
            storeUI?.store.cancel()
        }
        .transformEnvironment(\.dismissModalWindow) { action in
            if let prevAction = action {
                action = {
                    prevAction()
                    if canDismissModalWindow {
                        isPresented.wrappedValue = false
                    }
                }
            }
            else if canDismissModalWindow {
                action = { isPresented.wrappedValue = false }
            }
            else {
                action = nil
            }
        }
#endif
    }
}

extension View {
    public func fullScreenOrWindow<C: StoreUIContainer, V: View>(
        isPresented: Binding<Bool>,
        storeUI: C?,
        isModal: Bool = true, 
        content: @escaping () -> V?
    )
    -> some View {
        self.modifier(FullScreenOrWindow(isPresented: isPresented, storeUI: storeUI, isModal: isModal, content: content))
    }
}

public struct WindowContentView<C: StoreUIContainer>: View {
    let storeUI: C?
    
    struct ContentView: View {
        let storeUI: C
        @Environment(\.dismiss) private var dismiss
        
        @MainActor
        public init(storeUI: C) {
            self.storeUI = storeUI
        }
        
        var body: some View {
            storeUI.makeView()
                .onDisappear {
                    storeUI.cancel()
                }
                .onReceive(storeUI.store.isCancelledPublisher) { _ in
                    dismiss()
                }
        }
    }
    
    @MainActor
    public init(id: UUID?) {
        self.storeUI = id.flatMap { StoreUIContainers.get(id: $0) }
    }
    
    public var body: some View {
        if let storeUI {
            ContentView(storeUI: storeUI)
        }
    }
}

@available(iOS 16.0, *)
@available(macOS 13.0, *)
extension StoreUINamespace {
    @MainActor
    public static func windowGroup() -> WindowGroup<PresentedWindowContent<UUID, WindowContentView<StoreUI<Nsp>>>> where Nsp: StoreUINamespace {
        WindowGroup(id: Store.storeDefaultKey, for: UUID.self) { id in
            WindowContentView<StoreUI<Nsp>>(id: id.wrappedValue)
        }
    }
}
