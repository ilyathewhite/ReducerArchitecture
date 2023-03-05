//
//  ReducerArchitecture.swift
//  Rocket Insights
//
//  Created by Ilya Belenkiy on 03/30/21.
//  Copyright © 2021 Rocket Insights. All rights reserved.
//

import FoundationEx
#if canImport(SwiftUI)
import SwiftUI
#else
public typealias Animation = Void
public func withAnimation<Result>(_ animation: Animation? = nil, _ body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif

import Foundation
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

public protocol StoreNamespace: Namespace {
    associatedtype StoreEnvironment
    associatedtype StoreState
    associatedtype MutatingAction
    associatedtype EffectAction
    associatedtype PublishedValue
}

extension StoreNamespace {
    public typealias Store = StateStore<Self>
    public typealias Reducer = Store.Reducer
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

public struct AsyncResult<T: Equatable>: Equatable {
    public var value: T? {
        didSet {
            count += 1
        }
    }

    public init() {}

    private(set) var count = 0
}

public protocol AnyStore: AnyObject {
    associatedtype PublishedValue

    @MainActor var identifier: String { get }

    @MainActor var value: AnyPublisher<PublishedValue, Cancel> { get }
    @MainActor func publish(_ value: PublishedValue)
    @MainActor func cancel()
}

public enum StateAction<Nsp: StoreNamespace> {
    case mutating(Nsp.MutatingAction, animated: Bool = false, Animation? = .default)
    case effect(Nsp.EffectAction)
    case publish(Nsp.PublishedValue)
    case cancel
}

public enum StateEffect<Nsp: StoreNamespace> {
    public typealias Action = StateAction<Nsp>
    
    case action(Action)
    case actions([Action])
    case asyncAction(() async throws -> Action?)
    case asyncActions(() async throws -> [Action])
    case asyncActionSequence(() -> AsyncStream<Action>)
    case publisher(AnyPublisher<Action, Never>)
    case none // cannot use Effect? in Reducer because it breaks the compiler
}

public struct StateReducer<Nsp: StoreNamespace> {
    public typealias PublishedValue = Nsp.PublishedValue
    public typealias MutatingAction = Nsp.MutatingAction
    public typealias EffectAction = Nsp.EffectAction
    public typealias Environment = Nsp.StoreEnvironment
    public typealias Value = Nsp.StoreState
    
    public typealias Action = StateAction<Nsp>
    public typealias Effect = StateEffect<Nsp>

    let run: (inout Value, MutatingAction) -> Effect
    let effect: (Environment, Value, EffectAction) -> Effect

    public init(run: @escaping (inout Value, MutatingAction) -> Effect, effect: @escaping (Environment, Value, EffectAction) -> Effect) {
        self.run = run
        self.effect = effect
    }
}

extension StateReducer where EffectAction == Never {
    @MainActor
    public init(_ run: @escaping (inout Value, MutatingAction) -> Effect) {
        self = StateReducer(run: run, effect: { _, _, effectAction in .none })
    }
}

private actor TasksContainer {
    private typealias ActionTask = Task<Void, any Error>

    private enum TaskBox {
        case willStart
        case inProgress(ActionTask)
        
        func cancelTask() {
            switch self {
            case .inProgress(let task):
                task.cancel()
            default:
                return
            }
        }
    }

    private var tasks: [UUID: TaskBox] = [:]
    
    deinit {
        for (_, box) in tasks {
            box.cancelTask()
        }
        tasks.removeAll()
    }
    
    func removeTask(id: UUID) {
        tasks.removeValue(forKey: id)
    }
    
    func addTask(_ f: @escaping () async throws -> Void) {
        let id = UUID()
        tasks[id] = .willStart
        let task = Task { [weak self] in
            do {
                try await f()
                await self?.removeTask(id: id)
            }
            catch {
                await self?.removeTask(id: id)
                throw error
            }
        }
        
        if (self.tasks[id] != nil) && !task.isCancelled {
            self.tasks[id] = .inProgress(task)
        }
    }
}

// StateStore should not be subclassed because of a bug in SwiftUI
@MainActor
public final class StateStore<Nsp: StoreNamespace>: ObservableObject, AnyStore {
    public typealias Nsp = Nsp
    public typealias PublishedValue = Nsp.PublishedValue
    public typealias MutatingAction = Nsp.MutatingAction
    public typealias EffectAction = Nsp.EffectAction
    public typealias Environment = Nsp.StoreEnvironment
    public typealias State = Nsp.StoreState
    
    public typealias Reducer = StateReducer<Nsp>
    public typealias ValuePublisher = AnyPublisher<PublishedValue, Cancel>

    public var identifier: String

    public var environment: Environment?
    private let reducer: Reducer
    private let tasksContainer = TasksContainer()
    
    @Published public private(set) var state: State
    private var publishedValue = PassthroughSubject<PublishedValue, Cancel>()

    public init(_ identifier: String, _ initialValue: State, reducer: Reducer, env: Environment?) {
        self.identifier = identifier
        self.reducer = reducer
        self.state = initialValue
        self.environment = env
    }
    
    public convenience init(_ identifier: String, _ initialValue: State, reducer: Reducer)
    where Environment == Never, EffectAction == Never {
        self.init(identifier, initialValue, reducer: reducer, env: nil)
    }

    public convenience init(_ identifier: String, _ initialValue: State, reducer: Reducer) where Environment == Void {
        self.init(identifier, initialValue, reducer: reducer, env: ())
    }

    public func addEffect(_ effect: Reducer.Effect) {
        switch effect {
        case .action(let action):
            send(action)
            
        case .actions(let actions):
            for action in actions {
                send(action)
            }
            
        case .asyncAction(let f):
            Task {
                await tasksContainer.addTask { [weak self] in
                    if let action = try await f() {
                        self?.send(action)
                    }
                }
            }
            
        case .asyncActions(let f):
            Task {
                await tasksContainer.addTask { [weak self] in
                    let actions = try await f()
                    for action in actions {
                        self?.send(action)
                    }
                }
            }
            
        case .asyncActionSequence(let f):
            let actions = f()
            Task {
                await tasksContainer.addTask { [weak self] in
                    for await action in actions {
                        try Task.checkCancellation()
                        self?.send(action)
                    }
                }
            }
            
        case .publisher(let publisher):
            Task {
                await tasksContainer.addTask { [weak self] in
                    for await action in publisher.values {
                        try Task.checkCancellation()
                        self?.send(action)
                    }
                }
            }
            
        case .none:
            break
        }
    }

    public func send(_ action: Reducer.Action) {
        let effect: Reducer.Effect?
        switch action {
        case .mutating(let mutatingAction, let animate, let animation):
            if animate {
                effect = withAnimation(animation) { reducer.run(&state, mutatingAction) }
            }
            else {
                effect = reducer.run(&state, mutatingAction)
            }
        case .effect(let effectAction):
            guard let env = environment else {
                assertionFailure()
                return
            }
            effect = reducer.effect(env, state, effectAction)

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

    public func distinctValues<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool) -> AnyPublisher<Value, Never> {
        $state
            .map(keyPath)
            .removeDuplicates(by: compare)
            .eraseToAnyPublisher()
    }

    public func distinctValues<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> AnyPublisher<Value, Never> {
        distinctValues(on: keyPath, compare: ==)
    }

    public func bind<OtherNsp: StoreNamespace, OtherValue>(
        to otherStore: OtherNsp.Store,
        on keyPath: KeyPath<OtherNsp.StoreState, OtherValue>,
        with action: @escaping (OtherValue) -> Reducer.Action?,
        compare: @escaping (OtherValue, OtherValue) -> Bool
    ) {
        addEffect(
            .publisher(
                otherStore
                .distinctValues(on: keyPath, compare: compare)
                .compactMap { action($0) }
                .eraseToAnyPublisher()
            )
        )
    }

    public func bind<OtherNsp: StoreNamespace, OtherValue: Equatable>(
        to otherStore: OtherNsp.Store,
        on keyPath: KeyPath<OtherNsp.StoreState, OtherValue>,
        with action: @escaping (OtherValue) -> Reducer.Action?) {
        bind(to: otherStore, on: keyPath, with: action, compare: ==)
    }

    public func bindPublishedValue<OtherNsp: StoreNamespace>(
        of otherStore: OtherNsp.Store,
        with action: @escaping (OtherNsp.PublishedValue) -> Reducer.Action) {
            addEffect(
                .publisher(
                    otherStore.publishedValue.map { action($0) }
                        .catch { _ in Just(.cancel) }
                        .eraseToAnyPublisher()
                )
            )
    }

    public func result<T: Equatable>(_ keyPath: KeyPath<State, AsyncResult<T>>) -> AnySingleValuePublisher<T, Never> {
        let prevCount = state[keyPath: keyPath].count
        return self.$state
            .map { $0[keyPath: keyPath] }
            .removeDuplicates()
            .first { ($0.count > prevCount) && ($0.value != nil) }
            .compactMap { $0.value }
            .eraseType()
    }

    // MARK: - AnyStore

    public var value: AnyPublisher<PublishedValue, Cancel> {
        publishedValue
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    public var valueResult: AnyPublisher<Result<PublishedValue, Cancel>, Never> {
        publishedValue
            .receive(on: DispatchQueue.main)
            .map { .success($0) }
            .catch { Just(.failure($0)) }
            .eraseToAnyPublisher()
    }

    public func publish(_ value: PublishedValue) {
        send(.publish(value))
    }

    public func cancel() {
        send(.cancel)
    }
}
