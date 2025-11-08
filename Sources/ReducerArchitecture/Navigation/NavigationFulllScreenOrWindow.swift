//
//  ReducerArchitectureNavigation.swift
//
//  Created by Ilya Belenkiy on 3/28/23.
//

import Foundation
import Combine
import CombineEx
import os
import SwiftUI

@MainActor
enum StoreUIContainers {
    private static var dict: [UUID: any StoreUIContainer] = [:]

    static func add(_ storeUI: any StoreUIContainer) {
        guard dict[storeUI.id] == nil else { return }
        dict[storeUI.id] = storeUI
    }

    static func remove(id: UUID) {
        dict.removeValue(forKey: id)
    }

    static func get<C: StoreUIContainer>(id: UUID) -> C? {
        guard let anyStoreUI = dict[id] else { return nil }
        guard let storeUI = anyStoreUI as? C else {
            assertionFailure()
            return nil
        }
        return storeUI
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

extension StoreUINamespace {
    @MainActor
    public static func windowGroup() -> WindowGroup<PresentedWindowContent<UUID, WindowContentView<StoreUI<Nsp>>>> where Nsp: StoreUINamespace {
        WindowGroup(id: Store.storeDefaultKey, for: UUID.self) { id in
            WindowContentView<StoreUI<Nsp>>(id: id.wrappedValue)
        }
    }
}
