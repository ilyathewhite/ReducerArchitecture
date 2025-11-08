//
//  NavigationSwiftUIProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

import SwiftUI

@MainActor
public class NavigationPathContainer: ObservableObject, NavigationProxy {
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

    public func push<Nsp: StoreUINamespace>(_ storeUI: StoreUI<Nsp>) -> Int {
        assert(path.count == stack.count)
        internalChange = true
        defer {
            internalChange = false
        }
        stack.append(storeUI)
        path.append(storeUI)
        return currentIndex

    }

    public func replaceTop<Nsp: StoreUINamespace>(with storeUI: StoreUI<Nsp>) -> Int {
        assert(path.count == stack.count)
        internalChange = true
        defer {
            internalChange = false
        }

        stack.last?.cancel()
        stack.removeLast()
        path.removeLast()

        return push(storeUI)
    }

    public func popTo(_ index: Int) {
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
