//
//  ReducerArchitectureAppSettings.swift
//  
//
//  Created by Ilya Belenkiy on 5/13/23.
//

import Foundation
import FoundationEx
import SwiftUI

public protocol AppSettingsStoreStateType {
    init()
}

public enum AppSettingsNsp<StoreState: AppSettingsStoreStateType>: StoreNamespace {
    public typealias PublishedValue = Void
    public typealias StoreEnvironment = Never
    public typealias EffectAction = Never

    public enum MutatingAction {
        case setValue(any PropertyListRepresentable, update: (inout StoreState, any PropertyListRepresentable) -> Void )
    }
}

extension AppSettingsNsp {
    public static func setAction<T: PropertyListRepresentable>(
        _ keyPath: WritableKeyPath<Self.StoreState, T>,
        _ value: T
    )
    -> MutatingAction
    {
        .setValue(value) { state, value in
            guard let value = value as? T else {
                assertionFailure()
                return
            }
            state[keyPath: keyPath] = value
        }
    }
}

extension StateStore.Action {
    public static func set<StoreState, T: PropertyListRepresentable>(
        _ keyPath: WritableKeyPath<Nsp.StoreState, T>,
        _ value: T, animation: Animation? = nil
    )
    -> Self
    where Nsp == AppSettingsNsp<StoreState>
    {
        if let animation {
            return .mutating(Nsp.setAction(keyPath, value), animated: true, animation)
        }
        else {
            return .mutating(Nsp.setAction(keyPath, value))
        }
    }
}

extension StateStore {
    public func set<StoreState, T: PropertyListRepresentable>(
        _ keyPath: WritableKeyPath<Nsp.StoreState, T>,
        _ value: T, animation: Animation? = nil
    )
    where Nsp == AppSettingsNsp<StoreState>
    {
        send(.set(keyPath, value, animation: animation))
    }
    
    public func binding<StoreState, T: PropertyListRepresentable & Equatable>(
        _ keyPath: WritableKeyPath<Nsp.StoreState, T>,
        animation: Animation? = nil
    )
    -> Binding<T>
    where Nsp == AppSettingsNsp<StoreState>
    {
        self.binding(keyPath, { Nsp.setAction(keyPath, $0) }, animation: animation)
    }
    
    
    public func binding<StoreState, T: PropertyListRepresentable>(
        _ keyPath: WritableKeyPath<Nsp.StoreState, T>,
        animation: Animation? = nil
    )
    -> Binding<T?>
    where Nsp == AppSettingsNsp<StoreState>
    {
        .init(
            get: { [weak self] in
                self?.state[keyPath: keyPath]
            },
            set: { [weak self] in
                guard let self else { return }
                guard let value = $0 else {
                    assertionFailure()
                    return
                }
                self.set(keyPath, value, animation: animation)
            }
        )
    }
}

extension AppSettingsNsp {
    @MainActor
    public static func store() -> Store {
        Store(.init(), env: nil)
    }

    public static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case let .setValue(value, update):
            update(&state, value)
            return .none
        }
    }
}
