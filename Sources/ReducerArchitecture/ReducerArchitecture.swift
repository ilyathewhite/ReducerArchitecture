//
//  ReducerArchitecture.swift
//
//  Created by Ilya Belenkiy on 10/31/19.
//  Copyright © 2019 Ilya Belenkiy. All rights reserved.
//

import SwiftUI
import Combine
import CombineEx

public protocol Namespace {
    static var identifier: String { get }
}

public extension Namespace {
    static var identifier: String {
        "\(Self.self)"
    }
}

public enum UIValue<T> {
    case fromUI(T)
    case fromCode(T)

    public var value: T {
        switch self {
        case .fromUI(let res): return res
        case .fromCode(let res): return res
        }
    }

    public func wrapper() -> (T) -> Self {
        return {
            switch self {
            case .fromUI:
                return .fromUI($0)
            case .fromCode:
                return .fromCode($0)
            }
        }
    }

    public var isFromUI: Bool {
        switch self {
        case .fromUI: return true
        case .fromCode: return false
        }
    }
}

extension UIValue: Equatable where T: Equatable {}

public enum UIEndValue {
    case fromUI
    case fromCode

    public var isFromUI: Bool {
        switch self {
        case .fromUI: return true
        case .fromCode: return false
        }
    }
}

public protocol AnyStore {
    associatedtype PublishedValue

    var identifier: String { get }
    var value: AnyPublisher<PublishedValue, Cancel> { get }
    func publish(_ value: PublishedValue)
    func cancel()
}

public enum StateAction<MutatingAction, EffectAction, PublishedValue> {
    case mutating(MutatingAction)
    case effect(EffectAction)
    case noAction
    case publish(PublishedValue)
    case cancel
}

public typealias StateEffect<MutatingAction, EffectAction, PublishedValue> =
    AnyPublisher<StateAction<MutatingAction, EffectAction, PublishedValue>, Never>

public struct StateReducer<Environment, Value, MutatingAction, EffectAction, PublishedValue> {
    public typealias Action = StateAction<MutatingAction, EffectAction, PublishedValue>
    public typealias Effect = StateEffect<MutatingAction, EffectAction, PublishedValue>

    let run: (inout Value, MutatingAction) -> Effect?
    let effect: (Environment?, Value, EffectAction) -> Effect

    public init(run: @escaping (inout Value, MutatingAction) -> Effect?, effect: @escaping (Environment?, Value, EffectAction) -> Effect) {
        self.run = run
        self.effect = effect
    }

    public static func effect(_ body: @escaping () -> Action) -> Effect {
        Just(body()).eraseToAnyPublisher()
    }

    public static func effect(_ action: Action) -> Effect {
        Just(action).eraseToAnyPublisher()
    }

    public static func effect(_ action: MutatingAction) -> Effect {
        effect(.mutating(action))
    }

    public static func effect(_ action: EffectAction) -> Effect {
        effect(.effect(action))
    }
}

extension StateReducer where EffectAction == Never {
    public init(_ run: @escaping (inout Value, MutatingAction) -> Effect?) {
        self = StateReducer(run: run, effect: { _, _, effectAction in AnyPublisher(Just(.effect(effectAction))) })
    }
}

public class StateStore<Environment, State, MutatingAction, EffectAction, PublishedValue>: ObservableObject, AnyStore {
    public typealias Reducer = StateReducer<Environment, State, MutatingAction, EffectAction, PublishedValue>

    public var identifier: String

    public var environment: Environment?
    private let reducer: Reducer
    private var subscriptions = Set<AnyCancellable>()
    private var effects = PassthroughSubject<Reducer.Effect, Never>()

    @Published public private(set) var state: State
    private var publishedValue = PassthroughSubject<PublishedValue, Cancel>()

    private var sentActions = PassthroughSubject<Reducer.Action, Never>()
    public var sentMutatingActions: AnyPublisher<MutatingAction, Never>
    public var logActions = false

    public init(_ identifier: String, _ initialValue: State, reducer: Reducer) {
        self.identifier = identifier
        self.reducer = reducer
        self.state = initialValue

        sentMutatingActions = sentActions
            .compactMap { anyAction in
                switch anyAction {
                case .mutating(let action):
                    return action
                default:
                    return nil
                }
            }
            .eraseToAnyPublisher()

        effects
            .flatMap { $0 }
            .receive(on: DispatchQueue.main)
            // sink could use unowned self, but .receive(on:) has a bug where
            // it sends a buffered value after the stream was cancelled.
            // Using weak self is a workaround.
            // TODO: [maybe] reevaluate after fixing memory leaks
            .sink(receiveValue: { [weak self] in self?.send($0) })
            .store(in: &subscriptions)
    }

    public func addEffect(_ effect: Reducer.Effect) {
        effects.send(effect)
    }

    public func send(_ action: Reducer.Action) {
        if logActions {
            let appNamePrefix = ReducerArchitecture.env.appNamePrefix
            let actionDescr = "\(action)"
                .replacingOccurrences(of: appNamePrefix, with: "")
                .replacingOccurrences(of: "\(identifier).", with: "")
                .replacingOccurrences(of: "MutatingAction.", with: "")
                .replacingOccurrences(of: "EffectAction.", with: "")
            ReducerArchitecture.env.log("\(identifier): \(actionDescr)")
        }

        let effect: Reducer.Effect?
        switch action {
        case .mutating(let mutatingAction):
            effect = reducer.run(&state, mutatingAction)
        case .effect(let effectAction):
            effect = reducer.effect(environment, state, effectAction)
        case .noAction:
            effect = nil
        case .publish(let value):
            publishedValue.send(value)
            effect = nil
        case .cancel:
            publishedValue.send(completion: .failure(.cancel))
            effect = nil
        }

        if let e = effect {
            addEffect(e)
        }

        sentActions.send(action)
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

    public func bind<OtherEnvironment, OtherState, OtherValue, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>(
        to otherStore: StateStore<OtherEnvironment, OtherState, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>,
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

    public func bind<OtherEnvironment, OtherState, OtherValue: Equatable, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>(
        to otherStore: StateStore<OtherEnvironment, OtherState, OtherMutatingAction, OtherEffectAction, OtherPublishedValue>,
        on keyPath: KeyPath<OtherState, OtherValue>,
        with action: @escaping (OtherValue) -> Reducer.Action) {
        bind(to: otherStore, on: keyPath, with: action, compare: ==)
    }

    public func binding<Value>(_ keyPath: KeyPath<State, Value>, _ action: @escaping (Value) -> MutatingAction) -> Binding<Value> {
        return Binding(get: { self.state[keyPath: keyPath] }, set: { self.send(.mutating(action($0))) })
    }

    // MARK: - AnyStore

    public var value: AnyPublisher<PublishedValue, Cancel> {
        publishedValue.eraseToAnyPublisher()
    }

    public func publish(_ value: PublishedValue) {
        send(.publish(value))
    }

    public func cancel() {
        send(.cancel)
    }
}
