//
//  StringPicker.swift
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import ReducerArchitecture

enum StringPicker: StoreNamespace {
    typealias PublishedValue = String
    
    typealias StoreEnvironment = Never
    enum MutatingAction {
        case updateValue(String)
    }
    
    typealias EffectAction = Never
    
    struct StoreState {
        let title: String
        var value: String
    }
}

extension StringPicker {
    @MainActor
    static func store(title: String? = nil) -> Store {
        .init(identifier, .init(title: title ?? "Pick a string", value: ""), reducer: reducer())
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
