//
//  File.swift
//  
//
//  Created by Ilya Belenkiy on 8/28/21.
//

#if canImport(SwiftUI)
import SwiftUI

public extension StateStore {
    func binding<Value>(
        _ keyPath: KeyPath<State, Value>,
        _ action: @escaping (Value) -> MutatingAction,
        animation: Animation? = nil
    )
    ->
    Binding<Value> where Value: Equatable
    {
        return Binding(
            get: { self.state[keyPath: keyPath] },
            set: {
                if self.state[keyPath: keyPath] != $0 {
                    if let animation = animation {
                        self.send(.mutating(action($0), animated: true, animation))
                    }
                    else {
                        self.send(.mutating(action($0)))
                    }
                }
            }
        )
    }

    func readOnlyBinding<Value>(_ keyPath: KeyPath<State, Value>) -> Binding<Value> {
        return Binding(
            get: { self.state[keyPath: keyPath] },
            set: { _ in
                assertionFailure()
            }
        )
    }
}

@MainActor
public protocol StoreContentView: View {
    associatedtype Nsp: StoreNamespace
    typealias Store = Nsp.Store
    var store: Store { get }
    init(store: Store)
}

public protocol StoreUINamespace: StoreNamespace {
    associatedtype ContentView: StoreContentView where ContentView.Nsp == Self
    static func updateNavigationCount(_ store: Store) -> Void
}

public extension StoreUINamespace {
    static func updateNavigationCount(_ store: Store) -> Void {}
}

public extension StateStore where Nsp: StoreUINamespace {
    var contentView: Nsp.ContentView {
        Nsp.ContentView(store: self)
    }
}

/// A type that can be used to create a view from a store. Used in APIs related to navigation.
///
/// `store.contentView` also provides a way to create a view from the store, but using store directly is not possible
/// with `NavigationEnv` because the environment uses closures, and the closures whould have to be generic since
/// `Store` is a generic class with the `Nsp` type parameter.
///
/// Presentation APIs also use `StoreUIContainer`. This makes it easier to replace presentation with push navigation
/// and vice versa.
public protocol StoreUIContainer<Nsp>: Hashable, Identifiable {
    associatedtype Nsp: StoreUINamespace
    var store: Nsp.Store { get }
    init(_ store: Nsp.Store)
}

extension StoreUIContainer {
    @MainActor
    public func makeView() -> some View {
        store.contentView.id(store.id)
    }
    
    @MainActor
    public func makeAnyView() -> AnyView {
        AnyView(makeView())
    }
    
    public var id: Nsp.Store.ID {
        store.id
    }
    
    @MainActor
    public var value: Nsp.Store.ValuePublisher {
        store.value
    }

    @MainActor
    public var anyStore: any AnyStore {
        store
    }

    @MainActor
    public func cancel() {
        store.cancel()
    }
    
    @MainActor
    public func updateNavigationCount() {
        Nsp.updateNavigationCount(store)
    }
}

public struct StoreUI<Nsp: StoreUINamespace>: StoreUIContainer {
    public static func == (lhs: StoreUI<Nsp>, rhs: StoreUI<Nsp>) -> Bool {
        lhs.store === rhs.store
    }
    
    public let store: Nsp.Store

    public init(_ store: Nsp.Store) {
        self.store = store
    }
}

extension StoreUI {
    public init?(_ store: Nsp.Store?) {
        guard let store else { return nil }
        self.init(store)
    }
}

public extension View {
    @MainActor
    func showUI<C: StoreUIContainer>(_ keyPath: KeyPath<Self, C?>) -> Binding<Bool> {
        .init(
            get: {
                guard let storeUI = self[keyPath: keyPath] else {
                    return false
                }
                return !storeUI.store.isCancelled
            },
            set: { show in
                if !show {
                    self[keyPath: keyPath]?.cancel()
                }
            }
        )
    }

    /// A convenience API for running a sheet that is implemented using TRA.
    ///
    /// The sheet store can be described as a child store like this:
    /// ```Swift
    /// var editSyncUpUI: StoreUI<SyncUpForm>? { .init(store.child()) }
    /// ```
    /// and then the sheet can be described as
    /// ```Swift
    /// .sheet(self, \.editSyncUpUI) { ui in ui.makeView() }
    /// ```
    /// where `ui` is the container for the sheet UI.
    ///
    /// The sheet store can be temporarily added as a child as part of running an async task:
    /// ```Swift
    /// edit: {
    ///    let editorStore = SyncUpForm.store(...)
    ///    await store.run(editStore)
    /// }
    ///```
    @MainActor
    func sheet<C: StoreUIContainer, V1: View, V2: View>(
        _ view: V1,
        _ keyPath: KeyPath<V1, C?>,
        content: @escaping (C) -> V2
    ) -> some View {
        sheet(isPresented: view.showUI(keyPath)) {
            if let storeUI = view[keyPath: keyPath] {
                content(storeUI)
            }
        }
    }

    /// A convenience API for running an async task based alert.
    /// `continuation` is a binding to the saved continuation from the started
    /// async task.
    ///
    /// Example
    /// ```
    /// .taskAlert(
    ///    $endMeetingAlertResult,
    ///    actions: { complete in
    ///        Button("Save and end") {
    ///            complete(.saveAndEnd)
    ///        }
    ///        Button("Resume", role: .cancel) {
    ///            complete(.resume)
    ///        }
    ///    },
    ///    message: {
    ///        Text("What would you like to do?")
    ///    }
    ///)
    func taskAlert<R, S: StringProtocol, A: View, M: View>(
        _ title: S,
        _ continuation: Binding<CheckedContinuation<R, Never>?>,
        @ViewBuilder actions: (@escaping (R) -> Void) -> A,
        @ViewBuilder message: () -> M
    ) -> some View {
        alert(
            title,
            isPresented: .init(
                get: { continuation.wrappedValue != nil },
                set: { value in if !value { continuation.wrappedValue = nil } }
            ),
            actions: {
                if let continuation = continuation.wrappedValue {
                    actions { result in
                        continuation.resume(returning: result)
                    }
                }
                else {
                    Button("No actions") {
                    }
                }
            },
            message: message
        )
    }

    @MainActor
    func fullScreenOrWindow<V1: View, C: StoreUIContainer, V2: View>(
        contentView: V1,
        _ keyPath: KeyPath<V1, C?>,
        isModal: Bool = true,
        content: @escaping () -> V2
    ) -> some View {
        fullScreenOrWindow(isPresented: contentView.showUI(keyPath), storeUI: contentView[keyPath: keyPath]) {
            content()
        }
    }
}

#endif
