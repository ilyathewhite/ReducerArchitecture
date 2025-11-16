//
//  ReducerArchitectureNavigation.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/11/25.
//

#if canImport(UIKit)
import UIKit

extension UIKitNavigationFlow where Nsp: StoreUINamespace {
    public init(_ root: Nsp.Store, _ run: @escaping (Nsp.PublishedValue, _ proxy: NavigationProxy) async -> Void) {
        self.init(root: root, run: run)
    }
}

#endif

#if canImport(SwiftUI)
import SwiftUI

extension NavigationFlow where Nsp: StoreUINamespace {
    public init(_ root: Nsp.Store, _ run: @escaping (Nsp.PublishedValue, _ proxy: NavigationProxy) async -> Void) {
        self.init(root: root, run: run)
    }
}

#endif

#if os(macOS)

extension CustomNavigationFlow where Nsp: StoreUINamespace {
    public init(_ root: Nsp.Store, _ run: @escaping (Nsp.PublishedValue, _ proxy: NavigationProxy) async -> Void) {
        self.init(root: root, run: run)
    }
}

#endif

extension TestNavigationProxy {
    @MainActor
    public func getStore<Nsp: StoreUINamespace>(_ type: Nsp.Type, _ timeIndex: inout Int) async throws -> Nsp.Store {
        let value = await currentViewModelPublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let viewModel = value?.viewModel as? Nsp.ViewModel else {
            throw CurrentViewModelError.typeMismatch
        }
        timeIndex += 1
        return viewModel
    }

    @MainActor
    public func getStore<T: StoreNamespace>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T {
        let value = await currentViewModelPublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let viewModel = value?.viewModel as? T else {
            throw CurrentViewModelError.typeMismatch
        }
        timeIndex += 1
        return viewModel
    }
}


extension StoreUI {
    init(store: Nsp.Store) {
        self.init(store)
    }
}

