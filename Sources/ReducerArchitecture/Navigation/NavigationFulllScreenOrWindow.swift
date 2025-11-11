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
enum ViewModelUIContainers {
    private static var dict: [UUID: any ViewModelUIContainer] = [:]

    static func add(_ viewModelUIUI: any ViewModelUIContainer) {
        guard dict[viewModelUIUI.id] == nil else { return }
        dict[viewModelUIUI.id] = viewModelUIUI
    }

    static func remove(id: UUID) {
        dict.removeValue(forKey: id)
    }

    static func get<C: ViewModelUIContainer>(id: UUID) -> C? {
        guard let anyViewModelUI = dict[id] else { return nil }
        guard let viewModelUI = anyViewModelUI as? C else {
            assertionFailure()
            return nil
        }
        return viewModelUI
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

public struct FullScreenOrWindow<C: ViewModelUIContainer, V: View>: ViewModifier {
#if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @State private var id: UUID?
#endif
    
    let isPresented: Binding<Bool>
    let viewModelUI: C?
    let isModal: Bool
    let presentedContent: () -> V?
    
#if os(macOS)
    var canDismissModalWindow: Bool {
        isModal && isPresented.wrappedValue
    }
#endif
    
    public init(isPresented: Binding<Bool>, viewModelUI: C?, isModal: Bool, content: @escaping () -> V?) {
        self.isPresented = isPresented
        self.viewModelUI = viewModelUI
        self.isModal = isModal
        self.presentedContent = content
    }

    public func body(content: Content) -> some View {
#if os(iOS)
        content.fullScreenCover(isPresented: isPresented, content: presentedContent)
#else
        content.onChange(of: viewModelUI) { viewModelUI in
            if let viewModelUI {
                id = viewModelUI.id
                ViewModelUIContainers.add(viewModelUI)
                openWindow(id: C.Nsp.ViewModel.viewModelDefaultKey, value: viewModelUI.id)
            }
            else {
                if let id {
                    ViewModelUIContainers.remove(id: id)
                }
            }
        }
        .overlay {
            if isModal, id != nil, let viewModelUI, !viewModelUI.viewModel.isCancelled {
                Color.primary.opacity(0.1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        id = nil
                        viewModelUI.cancel()
                    }
            }
        }
        .onDisappear {
            id = nil
            viewModelUI?.viewModel.cancel()
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
    public func fullScreenOrWindow<C: ViewModelUIContainer, V: View>(
        isPresented: Binding<Bool>,
        viewModelUI: C?,
        isModal: Bool = true, 
        content: @escaping () -> V?
    )
    -> some View {
        self.modifier(FullScreenOrWindow(isPresented: isPresented, viewModelUI: viewModelUI, isModal: isModal, content: content))
    }
}

public struct WindowContentView<C: ViewModelUIContainer>: View {
    let viewModelUI: C?
    
    struct ContentView: View {
        let viewModelUI: C
        @Environment(\.dismiss) private var dismiss
        
        @MainActor
        public init(viewModelUI: C) {
            self.viewModelUI = viewModelUI
        }
        
        var body: some View {
            viewModelUI.makeView()
                .onDisappear {
                    viewModelUI.cancel()
                }
                .onReceive(viewModelUI.viewModel.isCancelledPublisher) { _ in
                    dismiss()
                }
        }
    }
    
    @MainActor
    public init(id: UUID?) {
        self.viewModelUI = id.flatMap { ViewModelUIContainers.get(id: $0) }
    }
    
    public var body: some View {
        if let viewModelUI {
            ContentView(viewModelUI: viewModelUI)
        }
    }
}

extension ViewModelUINamespace {
    @MainActor
    public static func windowGroup()
    -> WindowGroup<PresentedWindowContent<UUID, WindowContentView<ViewModelUI<Self>>>>
    {
        WindowGroup(id: ViewModel.viewModelDefaultKey, for: UUID.self) { id in
            WindowContentView<ViewModelUI<Self>>(id: id.wrappedValue)
        }
    }
}
