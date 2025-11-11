//
//  Presentation.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/8/25.
//

#if canImport(SwiftUI)
import SwiftUI

public extension View {
    @MainActor
    func showUI<C: ViewModelUIContainer>(_ keyPath: KeyPath<Self, C?>) -> Binding<Bool> {
        .init(
            get: {
                guard let viewModelUI = self[keyPath: keyPath] else {
                    return false
                }
                return !viewModelUI.viewModel.isCancelled
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
    func sheet<C: ViewModelUIContainer, V1: View, V2: View>(
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
    func fullScreenOrWindow<V1: View, C: ViewModelUIContainer, V2: View>(
        contentView: V1,
        _ keyPath: KeyPath<V1, C?>,
        isModal: Bool = true,
        content: @escaping () -> V2
    ) -> some View {
        fullScreenOrWindow(isPresented: contentView.showUI(keyPath), viewModelUI: contentView[keyPath: keyPath]) {
            content()
        }
    }
}

#endif
