//
//  ReducerArchitecture.swift
//
//  Created by Ilya Belenkiy on 10/31/19.
//  Copyright © 2019 Ilya Belenkiy. All rights reserved.
//

import SwiftUI
import Combine

public enum StateAction<MutatingAction, EffectAction, PublishedValue> {
    case mutating(MutatingAction)
    case effect(EffectAction)
    case noAction
    case publish(PublishedValue)
}

public typealias StateEffect<MutatingAction, EffectAction, PublishedValue> =
    AnyPublisher<StateAction<MutatingAction, EffectAction, PublishedValue>, Never>

public struct StateReducer<Value, MutatingAction, EffectAction, PublishedValue> {
    public typealias Action = StateAction<MutatingAction, EffectAction, PublishedValue>
    public typealias Effect = StateEffect<MutatingAction, EffectAction, PublishedValue>

    let run: (inout Value, MutatingAction) -> Effect?
    let effect: (Value, EffectAction) -> Effect

    public init(run: @escaping (inout Value, MutatingAction) -> Effect?, effect: @escaping (Value, EffectAction) -> Effect) {
        self.run = run
        self.effect = effect
    }

    public static func effect(_ body: @escaping () -> Action) -> Effect {
        Effect(
            Deferred {
                Future { promise in
                    promise(.success(body()))
                }
            }
        )
    }
}

extension StateReducer where EffectAction == Never {
    public init(_ run: @escaping (inout Value, MutatingAction) -> Effect?) {
        self = StateReducer(run: run, effect: { _, effectAction in AnyPublisher(Just(.effect(effectAction))) })
    }
}

public class StateStore<State, MutatingAction, EffectAction, PublishedValue>: ObservableObject {
    public typealias Reducer = StateReducer<State, MutatingAction, EffectAction, PublishedValue>

    private let reducer: Reducer
    private var subscriptions = Set<AnyCancellable>()
    private var effects = PassthroughSubject<Reducer.Effect, Never>()

    @Published public private(set) var state: State
    var publishedValue = PassthroughSubject<PublishedValue, Never>()

    public init(_ initialValue: State, reducer: Reducer) {
        self.reducer = reducer
        self.state = initialValue

        subscriptions.insert(
            effects
                .flatMap { $0 }
                .receive(on: RunLoop.main)
                .sink(receiveValue: { [weak self] in self?.send($0) })
        )
    }

    public func addEffect(_ effect: Reducer.Effect) {
        effects.send(effect)
    }

    public func send(_ action: Reducer.Action) {
        let effect: Reducer.Effect?
        switch action {
        case .mutating(let mutatingAction):
            effect = reducer.run(&state, mutatingAction)
        case .effect(let effectAction):
            effect = reducer.effect(state, effectAction)
        case .noAction:
            effect = nil
        case .publish(let value):
            publishedValue.send(value)
            effect = nil
        }

        if let e = effect {
            addEffect(e)
        }
    }

    public func updates<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool) -> AnyPublisher<Value, Never> {
        $state
            .map(keyPath)
            .removeDuplicates(by: compare)
            .dropFirst()
            .eraseToAnyPublisher()
    }

    public func updates<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> AnyPublisher<Value, Never> {
        updates(on: keyPath, compare: ==)
    }

    public func bind<OtherState, OtherValue, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>(
        to otherStore: StateStore<OtherState, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>,
        on keyPath: KeyPath<OtherState, OtherValue>,
        with action: @escaping (OtherValue) -> Reducer.Action,
        compare: @escaping (OtherValue, OtherValue) -> Bool
    ) {
        addEffect(
            otherStore
                .updates(on: keyPath, compare: compare)
                .map { action($0) }
                .eraseToAnyPublisher()
        )
    }

    public func bind<OtherState, OtherValue: Equatable, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>(
        to otherStore: StateStore<OtherState, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>,
        on keyPath: KeyPath<OtherState, OtherValue>,
        with action: @escaping (OtherValue) -> Reducer.Action) {
        bind(to: otherStore, on: keyPath, with: action, compare: ==)
    }

    public func binding<Value>(_ keyPath: KeyPath<State, Value>, _ action: @escaping (Value) -> MutatingAction) -> Binding<Value> {
        return Binding(get: { self.state[keyPath: keyPath] }, set: { self.send(.mutating(action($0))) })
    }
}
