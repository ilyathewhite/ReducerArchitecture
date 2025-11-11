//
//  ReducerArchitectureNavigation.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/11/25.
//

#if canImport(UIKit)
import UIKit

extension UIKitNavigationFlow where Nsp: StoreUINamespace {
    public init(_ root: Nsp.Store, _ run: @escaping (Nsp.PublishedValue, _: NavigationProxy) async -> Void) {
        self.init(root: root, run: run)
    }
}

#endif

#if canImport(SwiftUI)
import SwiftUI

extension NavigationFlow where Nsp: StoreUINamespace {
    public init(_ root: Nsp.Store, _ run: @escaping (Nsp.PublishedValue, _: NavigationProxy) async -> Void) {
        self.init(root: root, run: run)
    }
}

#endif

#if os(macOS)

extension CustomNavigationFlow where Nsp: StoreUINamespace {
    public init(_ root: Nsp.Store, _ run: @escaping (Nsp.PublishedValue, _: NavigationProxy) async -> Void) {
        self.init(root: root, run: run)
    }
}

#endif
