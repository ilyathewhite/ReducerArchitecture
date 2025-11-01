//
//  AsyncNavigationEnv.swift
//
//  Created by Codex.
//

import Foundation
import Combine
import CombineEx

@MainActor
public protocol AsyncNavigationProxy {
    /// Returns the index of the top component on the stack.
    var currentIndex: Int { get }

    /// Pushes the next UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    func push<Nsp: ViewModelUINamespace>(_ viewModelUI: ViewModelUI<Nsp>) -> Int

    /// Replaces the last UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    func replaceTop<Nsp: ViewModelUINamespace>(with viewModelUI: ViewModelUI<Nsp>) -> Int

    /// Pops the navigation stack to the component at `index`.
    func popTo(_ index: Int) -> Void
}

@MainActor
public extension AsyncNavigationProxy {
    func pop() {
        popTo(currentIndex - 1)
    }
}
