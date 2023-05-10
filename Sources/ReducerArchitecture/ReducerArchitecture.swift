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
import os

public protocol StoreNamespace {
    associatedtype StoreEnvironment
    associatedtype StoreState
    associatedtype MutatingAction
    associatedtype EffectAction
    associatedtype PublishedValue
}

extension StoreNamespace {
    public typealias Nsp = Self
    public typealias Store = StateStore<Self>
    public typealias Reducer = Store.Reducer
    
    @MainActor
    public static func reducer() -> Reducer where MutatingAction == Void, EffectAction == Never {
        .init { _, _ in .none }
    }
}

public extension StoreNamespace {
    static var identifier: String {
        "\(Self.self)"
    }
}

@MainActor
// Conformance to Hashable is necessary for SwiftUI navigation
public protocol AnyStore: AnyObject, Hashable, Identifiable {
    associatedtype PublishedValue

    var identifier: String { get }
    var isCancelled: Bool { get }
    var publishedValue: PassthroughSubject<PublishedValue, Cancel> { get }
    func publish(_ value: PublishedValue)
    func cancel()
    
    /// Indicates whether there is request for a published value.
    ///
    /// Useful for testing navigation flows.
    var hasRequest: Bool { get set }
}

// value, publish, cancel
public extension AnyStore {
    var value: AnyPublisher<PublishedValue, Cancel> {
        publishedValue
            .handleEvents(
                receiveOutput: { [weak self] _ in
                    assert(Thread.isMainThread)
                    self?.hasRequest = false
                },
                receiveRequest: { [weak self] demand in
                    assert(Thread.isMainThread)
                    self?.hasRequest = true
                }
            )
            .subscribe(on: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    var valueResult: AnyPublisher<Result<PublishedValue, Cancel>, Never> {
        value
            .map { .success($0) }
            .catch { Just(.failure($0)) }
            .eraseToAnyPublisher()
    }
    
    func firstValue() async throws -> PublishedValue {
        try await value.first().async()
    }
    
    func publish(_ value: PublishedValue) {
        if isStateStore  {
            assertionFailure()
        }
        publishedValue.send(value)
    }
    
    func cancel() {
        if isStateStore  {
            assertionFailure()
        }
        publishedValue.send(completion: .failure(.cancel))
    }
    
    var isStateStore: Bool {
        "\(type(of: self))".hasPrefix("StateStore<")
    }
}

// Identifiable, Hashable
public extension AnyStore {
    nonisolated
    var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }
    
    nonisolated
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }
    
    nonisolated
    func hash(into hasher: inout Hasher) {
        ObjectIdentifier(self).hash(into: &hasher)
    }
}

// Navigation
public extension AnyStore {
    var throwingAsyncValues: AsyncThrowingPublisher<AnyPublisher<PublishedValue, Cancel>> {
        value.values
    }

    var asyncValues: AsyncPublisher<AnyPublisher<PublishedValue, Never>> {
        value
            .catch { _ in Empty<PublishedValue, Never>() }
            .eraseToAnyPublisher()
            .values
    }
    
    func get(callback: @escaping (PublishedValue) async throws -> Void) async throws {
        try await asyncValues.get(callback: callback)
    }
    
    func get(callback: @escaping (PublishedValue) async -> Void) async {
        await asyncValues.get(callback: callback)
    }
    
    func getFirst(callback: @escaping (PublishedValue) async -> Void) async {
        if let firstValue = try? await value.first().async() {
            await callback(firstValue)
        }
    }
    
    func getFirst(callback: @escaping (PublishedValue) async throws -> Void) async throws {
        let firstValue = try await value.first().async()
        try await callback(firstValue)
    }
}

// StateStore should not be subclassed because of a bug in SwiftUI
@MainActor
public final class StateStore<Nsp: StoreNamespace>: ObservableObject {
    public typealias Nsp = Nsp
    public typealias PublishedValue = Nsp.PublishedValue
    public typealias MutatingAction = Nsp.MutatingAction
    public typealias EffectAction = Nsp.EffectAction
    public typealias Environment = Nsp.StoreEnvironment
    public typealias State = Nsp.StoreState
    
    public typealias ValuePublisher = AnyPublisher<PublishedValue, Cancel>
    
    public enum Action {
        case mutating(MutatingAction, animated: Bool = false, Animation? = nil)
        case effect(EffectAction)
        case publish(PublishedValue)
        case cancel
        case none
    }
    
    public enum StoreAction {
        case user(Action)
        case code(Action)
        
        var action: Action {
            switch self {
            case .user(let action):
                return action
            case .code(let action):
                return action
            }
        }
        
        var isFromUser: Bool {
            switch self {
            case .user:
                return true
            case .code:
                return false
            }
        }
    }
    
    public enum SyncEffect {
        case action(Action)
        case actions([Action])
        case none // cannot use Effect? in Reducer because it breaks the compiler
    }
    
    public enum Effect {
        case action(Action)
        case actions([Action])
        case asyncAction(() async -> Action)
        case asyncActions(() async -> [Action])
        case asyncActionSequence(() -> AsyncStream<Action>)
        case publisher(AnyPublisher<Action, Never>)
        case none // cannot use Effect? in Reducer because it breaks the compiler
        
        init(_ e: SyncEffect) {
            switch e {
            case .action(let value):
                self = .action(value)
            case .actions(let value):
                self = .actions(value)
            case .none:
                self = .none
            }
        }
    }
    
    public struct Reducer {
        public typealias Value = Nsp.StoreState
        
        let run: (inout Value, MutatingAction) -> SyncEffect
        let effect: (Environment, Value, EffectAction) -> Effect
        
        public init(run: @escaping (inout Value, MutatingAction) -> SyncEffect, effect: @escaping (Environment, Value, EffectAction) -> Effect) {
            self.run = run
            self.effect = effect
        }
    }
    
    public var identifier: String
    private var nestedLevel = 0
    
    public var environment: Environment?
    internal let reducer: Reducer
    private let taskManager = TaskManager()
    
    public var logConfig = LogConfig()
    internal var logger: Logger
    private var codeStringSnapshots: [ReducerSnapshotData] = []
    
    @Published public private(set) var state: State
    public private(set) var publishedValue = PassthroughSubject<PublishedValue, Cancel>()
    public private(set) var isCancelled = false
    public var hasRequest = false
    
    public init(_ identifier: String, _ initialValue: State, reducer: Reducer, env: Environment?) {
        self.identifier = identifier
        self.reducer = reducer
        self.state = initialValue
        self.environment = env
        
        logger = Logger(subsystem: "ReducerStore", category: identifier)
    }
    
    public convenience init(_ identifier: String, _ initialValue: State, reducer: Reducer)
    where Environment == Never, EffectAction == Never {
        self.init(identifier, initialValue, reducer: reducer, env: nil)
    }
    
    public convenience init(_ identifier: String, _ initialValue: State, reducer: Reducer) where Environment == Void {
        self.init(identifier, initialValue, reducer: reducer, env: ())
    }
    
    public func addEffect(_ effect: Effect) {
        switch effect {
        case .action(let action):
            send(.code(action))
            
        case .actions(let actions):
            for action in actions {
                send(.code(action))
            }
            
        case .asyncAction(let f):
            Task {
                await taskManager.addTask { [weak self] in
                    let action = await f()
                    self?.send(.code(action))
                }
            }
            
        case .asyncActions(let f):
            Task {
                await taskManager.addTask { [weak self] in
                    let actions = await f()
                    for action in actions {
                        self?.send(.code(action))
                    }
                }
            }
            
        case .asyncActionSequence(let f):
            let actions = f()
            Task {
                await taskManager.addTask { [weak self] in
                    for await action in actions {
                        guard !Task.isCancelled else { return }
                        self?.send(.code(action))
                    }
                }
            }
            
        case .publisher(let publisher):
            Task {
                await taskManager.addTask { [weak self] in
                    for await action in publisher.values {
                        guard !Task.isCancelled else { return }
                        self?.send(.code(action))
                    }
                }
            }
            
        case .none:
            break
        }
    }
    
    public func send(_ action: Action) {
        send(.user(action))
    }
    
    private func send(_ storeAction: StoreAction) {
        guard !isCancelled else {
            logger.error("Tried to send action \n\(codeString(storeAction))\n to store \(self.identifier) that is already cancelled.")
            return
        }
        
        var reducerInput = ""
        if logConfig.logActions {
            reducerInput.append("\n->\n\(codeString(storeAction))")
        }
        if logConfig.logState {
            reducerInput.append("\n->\n\(codeString(state))")
        }
        if logConfig.logActions || logConfig.logState {
            logger.debug("\(reducerInput)")
        }
        
        if logConfig.saveSnapshots {
            let snapshot: Snapshot = Snapshot.Input(date: .now, action: storeAction, state: state, nestedLevel: nestedLevel).snapshot
            codeStringSnapshots.append(snapshot.logData(errorLogger: logger))
        }
        
        let effect: Effect?
        let syncEffect: SyncEffect?
        switch storeAction.action {
        case .mutating(let mutatingAction, let animate, let animation):
            if animate {
                syncEffect = withAnimation(animation ?? .default) { reducer.run(&state, mutatingAction) }
            }
            else {
                syncEffect = reducer.run(&state, mutatingAction)
            }
            effect = syncEffect.map { .init($0) }
            
            if logConfig.logState {
                var reducerStateChange = "\n<-"
                reducerStateChange.append("\n\(codeString(state))")
                logger.debug("\(reducerStateChange)")
            }
            
            if logConfig.saveSnapshots {
                let snapshot = Snapshot.StateChange(date: .now, state: state, nestedLevel: nestedLevel).snapshot
                codeStringSnapshots.append(snapshot.logData(errorLogger: logger))
            }
            
        case .effect(let effectAction):
            guard let env = environment else {
                assertionFailure()
                return
            }
            
            // When executing an effect, the environment may send more messages to the store while
            // inside this call
            nestedLevel += 1
            syncEffect = nil
            effect = reducer.effect(env, state, effectAction)
            nestedLevel -= 1
            
        case .publish(let value):
            publishedValue.send(value)
            syncEffect = nil
            effect = nil
            
        case .cancel:
            publishedValue.send(completion: .failure(.cancel))
            isCancelled = true
            syncEffect = nil
            effect = nil
            
        case .none:
            syncEffect = nil
            effect = nil
        }
        
        if logConfig.logActions {
            var reducerOutput = "\n<-"
            reducerOutput.append("\n\(codeString(effect))")
            logger.debug("\(reducerOutput)")
        }
        
        if logConfig.saveSnapshots {
            let snapshot = Snapshot.Output(
                date: Date.now,
                effect: effect,
                syncEffect: syncEffect,
                state: state,
                nestedLevel: nestedLevel
            )
                .snapshot
            codeStringSnapshots.append(snapshot.logData(errorLogger: logger))
        }
        
        if let e = effect {
            addEffect(e)
        }
    }
}

public extension StateStore {
    func updates<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool) -> AnyPublisher<Value, Never> {
            $state
                .map(keyPath)
                .removeDuplicates(by: compare)
                .dropFirst()
                .eraseToAnyPublisher()
        }
    
    func updates<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> AnyPublisher<Value, Never> {
        updates(on: keyPath, compare: ==)
    }
    
    func distinctValues<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool) -> AnyPublisher<Value, Never> {
            $state
                .map(keyPath)
                .removeDuplicates(by: compare)
                .eraseToAnyPublisher()
        }
    
    func distinctValues<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> AnyPublisher<Value, Never> {
        distinctValues(on: keyPath, compare: ==)
    }
    
    func bind<OtherNsp: StoreNamespace, OtherValue>(
        to otherStore: OtherNsp.Store,
        on keyPath: KeyPath<OtherNsp.StoreState, OtherValue>,
        with action: @escaping (OtherValue) -> Action?,
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
    
    func bind<OtherNsp: StoreNamespace, OtherValue: Equatable>(
        to otherStore: OtherNsp.Store,
        on keyPath: KeyPath<OtherNsp.StoreState, OtherValue>,
        with action: @escaping (OtherValue) -> Action?
    ) {
        bind(to: otherStore, on: keyPath, with: action, compare: ==)
    }
    
    func bindPublishedValue<OtherNsp: StoreNamespace>(
        of otherStore: OtherNsp.Store,
        with action: @escaping (OtherNsp.PublishedValue
    )
    -> Action)
    {
        addEffect(
            .publisher(
                otherStore.value.map { action($0) }
                    .catch { _ in Just(.cancel) }
                    .eraseToAnyPublisher()
            )
        )
    }
}

extension StateStore: AnyStore {
    public func publish(_ value: PublishedValue) {
        send(.publish(value))
    }
    
    public func cancel() {
        send(.cancel)
    }
}

// MARK: -  Snapshots and Logging

extension StateStore {
    public struct LogConfig {
        public var logState = false
        public var logActions = false
        public var saveSnapshots = false
        
        var logEnabled: Bool {
            logState || logActions
        }
    }
        
    public enum Snapshot {
        public struct Input {
            let date: Date
            let action: StoreAction
            let state: State
            let nestedLevel: Int
            
            var snapshot: Snapshot {
                .input(self)
            }
            
            var isFromUser: Bool {
                action.isFromUser
            }
        }
        
        public struct StateChange {
            let date: Date
            let state: State
            let nestedLevel: Int

            var snapshot: Snapshot {
                .stateChange(self)
            }
        }
        
        public struct Output {
            let date: Date
            let effect: Effect?
            let syncEffect: SyncEffect?
            let state: State
            let nestedLevel: Int

            var snapshot: Snapshot {
                .output(self)
            }
        }
        
        case input(Input)
        case stateChange(StateChange)
        case output(Output)
        
        private static func encode<T>(_ value: T, _ logger: Logger) -> Data? {
            guard let codable = value as? Codable else { return nil }
            let encoder = JSONEncoder()
            do {
                return try encoder.encode(codable)
            }
            catch {
                logger.error(message: "Failed to encode \(value)", error)
                return nil
            }
        }
        
        public func logData(errorLogger logger: Logger) -> ReducerSnapshotData {
            switch self {
            case .input(let input):
                let mutatingAction: MutatingAction?
                switch input.action.action {
                case .mutating(let action, _, _):
                    mutatingAction = action
                default:
                    mutatingAction = nil
                }
                
                return ReducerSnapshotData.Input(
                    date: input.date,
                    action: codeString(input.action),
                    encodedAction: Self.encode(input.action, logger),
                    encodedMutatingAction: mutatingAction.flatMap { Self.encode($0, logger) },
                    state: propertyCodeStrings(input.state),
                    encodedState: Self.encode(input.state, logger),
                    nestedLevel: input.nestedLevel
                )
                .snapshotData
                
            case .stateChange(let stateChange):
                return ReducerSnapshotData.StateChange(
                    date: stateChange.date,
                    state: propertyCodeStrings(stateChange.state),
                    encodedState: Self.encode(stateChange.state, logger),
                    nestedLevel: stateChange.nestedLevel
                )
                .snapshotData
                
            case .output(let output):
                return ReducerSnapshotData.Output(
                    date: output.date,
                    effect: codeString(output.effect),
                    encodedEffect: (output.effect is any Equatable) ? output.effect.flatMap { Self.encode($0, logger) } : nil,
                    encodedSyncEffect: (output.syncEffect is any Equatable) ? output.syncEffect.flatMap { Self.encode($0, logger) } : nil,
                    state: propertyCodeStrings(output.state),
                    encodedState: (output.state is any Equatable) ? Self.encode(output.state, logger) : nil,
                    nestedLevel: output.nestedLevel
                )
                .snapshotData
            }
        }
        
        public var isFromUser: Bool {
            switch self {
            case .input(let input):
                return input.isFromUser
            default:
                return false
            }
        }
    }
    
    private func clearSnapshots() {
        codeStringSnapshots = []
    }
    
    @MainActor
    public func saveSnapshotsIfNeeded() {
        guard logConfig.saveSnapshots else { return }
        let snapshotCollection = ReducerSnapshotCollection(title: identifier, snapshots: codeStringSnapshots)
        do {
            if let path = try snapshotCollection.save() {
                logger.info("Saved reducer snapshots to \n\(path)")
                clearSnapshots()
            }
            else {
                logger.error("Failed to save snapshots.")
            }
        }
        catch {
            logger.error(message: "Failed to save snapshots.", error)
        }
    }
}

extension StateStore.Action: Codable
where Nsp.MutatingAction: Codable, Nsp.EffectAction: Codable, Nsp.PublishedValue: Codable {
    public enum Base: Codable {
        case mutating(Nsp.MutatingAction)
        case effect(Nsp.EffectAction)
        case publish(Nsp.PublishedValue)
        case cancel
        case none
        
        init(_ value: StateStore.Action) {
            switch value {
            case .mutating(let action, _, _):
                self = .mutating(action)
            case .effect(let action):
                self = .effect(action)
            case .publish(let value):
                self = .publish(value)
            case .cancel:
                self = .cancel
            case .none:
                self = .none
            }
        }
    }
    
    init(_ value: Base) {
        switch value {
        case .mutating(let action):
            self = .mutating(action)
        case .effect(let action):
            self = .effect(action)
        case .publish(let value):
            self = .publish(value)
        case .cancel:
            self = .cancel
        case .none:
            self = .none
            
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        try Base(self).encode(to: encoder)
    }
    
    public init(from decoder: Decoder) throws {
        self = try .init(Base.init(from: decoder))
    }
}

extension StateStore.Action: Equatable
where Nsp.MutatingAction: Equatable, Nsp.EffectAction: Equatable, Nsp.PublishedValue: Equatable {
}

extension StateStore.StoreAction: Equatable where StateStore.Action: Equatable {
}

extension StateStore.StoreAction: Codable where StateStore.Action: Codable {
}

extension StateStore.Effect where StateStore.Action: Equatable {
    func isEqual(to other: Self) -> Bool? {
        switch (self, other) {
        case let (.action(action), .action(otherAction)):
            return action == otherAction
        case let (.actions(actions), .actions(otherActions)):
            return actions == otherActions
        case (.asyncAction, .asyncAction):
            return nil
        case (.asyncActions, .asyncActions):
            return nil
        case (.asyncActionSequence, .asyncActionSequence):
            return nil
        case (.publisher, .publisher):
            return nil
        case (.none, .none):
            return true
        default:
            if codeString(self) == codeString(other) { // maybe unknown new case
                return nil
            }
            return false
        }
    }
}

extension StateStore.SyncEffect: Codable where StateStore.Action: Codable {
}

extension StateStore.SyncEffect: Equatable where StateStore.Action: Equatable {
}

extension StateStore.Reducer where Nsp.EffectAction == Never {
    @MainActor
    public init(_ run: @escaping (inout Value, Nsp.MutatingAction) -> StateStore.SyncEffect) {
        self = StateStore.Reducer(run: run, effect: { _, _, effectAction in .none })
    }
}
