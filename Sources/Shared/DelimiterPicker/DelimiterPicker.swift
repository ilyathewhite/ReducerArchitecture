//
//  IntPicker.swift
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import FoundationEx
import ReducerArchitecture

enum DelimiterPicker: StoreNamespace {
    enum Delimiter: String, CaseIterable, IdentifiableAsSelf {
        case pipe = "|"
        case forwardSlash = "/"
        case dash = "-"
    }
    
    typealias PublishedValue = Delimiter
    
    typealias StoreEnvironment = Never
    enum MutatingAction {
        case updateValue(Delimiter)
    }
    
    typealias EffectAction = Never
    
    struct StoreState {
        var value: Delimiter?
    }
}

extension DelimiterPicker {
    @MainActor
    static func store() -> Store {
        .init(.init(value: nil), reducer: reducer())
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
