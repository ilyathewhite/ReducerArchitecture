//
//  IntPicker.swift
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import ReducerArchitecture

enum IntPicker: StoreNamespace {
    typealias PublishedValue = Int
    
    typealias StoreEnvironment = Never
    enum MutatingAction {
        case updateValue(Int)
    }
    
    typealias EffectAction = Never
    
    struct StoreState {
        var value: Int?
    }
}

extension IntPicker {
    @MainActor
    static func store() -> Store {
        .init(.init(), reducer: reducer())
    }
    
    @MainActor
    static func reducer() -> Reducer {
        .init { state, action in
            switch action {
            case .updateValue(let value):
                state.value = value
                return .none
            }
        }
    }
}
