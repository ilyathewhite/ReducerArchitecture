//
//  NavigationTestProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/3/25.
//

import Foundation
import Combine
import CombineEx

class NavigationTestProxy: NavigationProxy {
    class PlaceholderViewModel: BasicViewModel {
        var publishedValue: PassthroughSubject<Void, Cancel> = .init()

        func publish(_ value: Void) {
            _publish(value)
        }
        
        typealias PublishedValue = Void

        var id: UUID = .init()
        var name = ""
        var isCancelled = false

        func cancel() {
            isCancelled = true
            _cancel()
        }

        var hasRequest = false
        var children: [String : any BasicViewModel] = [:]
    }

    @MainActor
    struct ViewModelInfo {
        let timeIndex: Int
        let viewModel: any BasicViewModel

        static let placeholder = Self.init(timeIndex: -1, viewModel: PlaceholderViewModel())
    }

    enum CurrentViewModelError: Error {
        case typeMismatch
    }

    public private(set) var stack: [any ViewModelUIContainer] = []
    let currentViewModelPublisher: CurrentValueSubject<ViewModelInfo, Never> = .init(.placeholder)

    /// Returns the viewModel of a particular type for a given time index.
    ///
    /// Used only for testing.
    @MainActor
    public func getViewModel<Nsp: ViewModelUINamespace>(_ type: Nsp.Type, _ timeIndex: inout Int) async throws -> Nsp.ViewModel {
        let value = await currentViewModelPublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let viewModel = value?.viewModel as? Nsp.ViewModel else {
            throw CurrentViewModelError.typeMismatch
        }
        timeIndex += 1
        return viewModel
    }

    /// Returns the viewModel of a particular type for a given time index.
    ///
    /// Used only for testing.
    @MainActor
    public func getViewModel<T: BasicViewModel>(_ type: T.Type, _ timeIndex: inout Int) async throws -> T {
        let value = await currentViewModelPublisher.values.first(where: { $0.timeIndex == timeIndex })
        guard let viewModel = value?.viewModel as? T else {
            throw CurrentViewModelError.typeMismatch
        }
        timeIndex += 1
        return viewModel
    }

    @MainActor
    /// Used only for testing.
    public func backAction() {
        return pop()
    }

    func updateCurrentViewModel() {
        guard let viewModel = stack.last?.anyViewModel else {
            assertionFailure()
            return
        }
        let timeIndex = currentViewModelPublisher.value.timeIndex + 1
        currentViewModelPublisher.send(.init(timeIndex: timeIndex, viewModel: viewModel))
    }

    var currentIndex: Int {
        stack.count - 1
    }

    public func push<Nsp: ViewModelUINamespace>(_ viewModelUI: ViewModelUI<Nsp>) -> Int {
        stack.append(viewModelUI)
        updateCurrentViewModel()
        return stack.count - 1
    }

    public func replaceTop<Nsp: ViewModelUINamespace>(with viewModelUI: ViewModelUI<Nsp>) -> Int {
        guard let last = stack.last else {
            assertionFailure()
            return 0
        }
        last.cancel()

        stack[stack.count - 1] = viewModelUI
        updateCurrentViewModel()
        return stack.count - 1
    }

    public func popTo(_ index: Int) {
        guard -1 <= index, index < stack.count else {
            assertionFailure()
            return
        }
        let k = stack.count - 1 - index
        // cancel order should be in reverse of push order
        var valuesToCancel: [any BasicViewModel] = []
        for _ in 0..<k {
            let viewModelUI = stack.removeLast()
            valuesToCancel.append(viewModelUI.anyViewModel)
        }

        for value in valuesToCancel {
            value.cancel()
        }

        updateCurrentViewModel()
    }
}

