//
//  Done.swift
//  TestsApp
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import ReducerArchitecture

enum Done: StoreNamespace {
    typealias PublishedValue = Void
    
    typealias StoreEnvironment = Never
    typealias MutatingAction = Void
    typealias EffectAction = Never

    struct StoreState {
        let value: String
    }
}

extension Done {
    @MainActor
    static func store(value: String) -> Store {
        .init(.init(value: value), env: nil)
    }
}
