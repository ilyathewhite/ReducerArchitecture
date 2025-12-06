//
//  ReducerArchitectureNavigation.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/11/25.
//

import AsyncNavigation

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
