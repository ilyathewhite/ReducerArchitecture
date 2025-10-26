//
//  AsyncNavigationEnv.swift
//
//  Created by Codex.
//

import Foundation
import Combine
import CombineEx

@MainActor
private final class AsyncNavigationEnvPlaceholderViewModel: AnyViewModel {
    typealias PublishedValue = Void

    nonisolated let id = UUID()
    nonisolated let name = "AsyncNavigationEnvPlaceholder"
    var isCancelled = false
    var hasRequest = false
    let publishedValue = PassthroughSubject<Void, Cancel>()

    nonisolated static var storeDefaultKey: String { "AsyncNavigationEnvPlaceholder" }

    func publish(_ value: Void) {
        publishedValue.send(value)
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        publishedValue.send(completion: .failure(.cancel))
    }
}

public struct AsyncNavigationEnv {
    @MainActor
    struct ViewModelInfo {
        let timeIndex: Int
        let viewModel: any AnyViewModel

        static let placeholder = Self(timeIndex: -1, viewModel: AsyncNavigationEnvPlaceholderViewModel())
    }

    /// Returns the index of the top component on the stack.
    public let currentIndex: @MainActor () -> Int

    /// Pushes the next UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    public let push: @MainActor (any ViewModelUIContainer & Hashable) -> Int

    /// Replaces the last UI component on the navigation stack.
    /// Returns the index of the pushed component on the navigation stack.
    public let replaceTop: @MainActor (any ViewModelUIContainer & Hashable) -> Int

    /// Pops the navigation stack to the component at `index`.
    public let popTo: @MainActor (_ index: Int) -> Void

    /// Provides the navigation stack top view model whenever the navigation stack changes.
    ///
    /// Available only when testing.
    private let currentViewModelPublisher: CurrentValueSubject<ViewModelInfo, Never>

    public init(
        currentIndex: @escaping () -> Int,
        push: @escaping (any ViewModelUIContainer & Hashable) -> Int,
        replaceTop: @escaping (any ViewModelUIContainer & Hashable) -> Int,
        popTo: @escaping (_: Int) -> Void
    ) {
        self.init(
            currentIndex: currentIndex,
            push: push,
            replaceTop: replaceTop,
            popTo: popTo,
            currentViewModelPublisher: .init(.placeholder)
        )
    }

    init(
        currentIndex: @escaping () -> Int,
        push: @escaping (any ViewModelUIContainer & Hashable) -> Int,
        replaceTop: @escaping (any ViewModelUIContainer & Hashable) -> Int,
        popTo: @escaping (_: Int) -> Void,
        currentViewModelPublisher: CurrentValueSubject<ViewModelInfo, Never>
    ) {
        self.currentIndex = currentIndex
        self.push = push
        self.replaceTop = replaceTop
        self.popTo = popTo
        self.currentViewModelPublisher = currentViewModelPublisher
    }
}

@MainActor
public extension AsyncNavigationEnv {
    func pop() {
        popTo(currentIndex() - 1)
    }
}

extension AsyncNavigationEnv {
    enum NavigationTestNode {
        case viewModelUI(any ViewModelUIContainer)

        var viewModel: (any AnyViewModel)? {
            switch self {
            case .viewModelUI(let container):
                return AsyncNavigationEnv.getViewModel(container)
            }
        }
    }

    enum CurrentViewModelError: Error {
        case typeMismatch
    }

    static func getViewModel(_ container: some ViewModelUIContainer) -> any AnyViewModel {
        container.viewModel
    }

    /// Returns the view model of a particular type for a given time index.
    ///
    /// Used only for testing.
    @MainActor
    public func getViewModel<T: AnyViewModel>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T {
        let value = await currentViewModelPublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let viewModel = value?.viewModel as? T else {
            throw CurrentViewModelError.typeMismatch
        }
        timeIndex += 1
        return viewModel
    }

    @MainActor
    /// Used only for testing.
    public static func testEnv() -> AsyncNavigationEnv {
        let currentViewModelPublisher: CurrentValueSubject<ViewModelInfo, Never> = .init(.placeholder)
        var stack: [NavigationTestNode] = []

        func updateCurrent() {
            guard let viewModel = stack.last?.viewModel else {
                assertionFailure()
                return
            }
            let nextIndex = currentViewModelPublisher.value.timeIndex + 1
            currentViewModelPublisher.send(.init(timeIndex: nextIndex, viewModel: viewModel))
        }

        return .init(
            currentIndex: {
                stack.count - 1
            },
            push: {
                stack.append(.viewModelUI($0))
                updateCurrent()
                return stack.count - 1
            },
            replaceTop: {
                guard !stack.isEmpty else {
                    assertionFailure()
                    return 0
                }
                stack.removeLast().viewModel?.cancel()
                stack.append(.viewModelUI($0))
                updateCurrent()
                return stack.count - 1
            },
            popTo: { index in
                guard -1 <= index, index < stack.count else {
                    assertionFailure()
                    return
                }
                let count = stack.count - 1 - index
                var toCancel: [any AnyViewModel] = []
                for _ in 0..<count {
                    guard let viewModel = stack.removeLast().viewModel else {
                        assertionFailure()
                        continue
                    }
                    toCancel.append(viewModel)
                }
                toCancel.forEach { $0.cancel() }
                updateCurrent()
            },
            currentViewModelPublisher: currentViewModelPublisher
        )
    }
}

public extension AnyViewModel {
    func publishOnRequest(_ value: PublishedValue) async {
        while !hasRequest {
            await Task.yield()
        }
        publish(value)
    }
}
