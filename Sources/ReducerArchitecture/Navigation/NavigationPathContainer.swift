//
//  NavigationPathContainer.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

import SwiftUI

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

public extension NavigationPath {
    mutating func push<T: StoreUINamespace>(_ storeUI: StoreUI<T>) {
        append(storeUI)
    }
}

