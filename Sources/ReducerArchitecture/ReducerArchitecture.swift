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

/// Logs store allocation, cancellation, and deallocation. The default is `false`.
public struct StoreLifecycleLog {
    public var enabled = false
    public var debug = false
    public private (set) var lastEvent: [UUID: (name: String, event: String)] = [:]
    
    mutating func addEvent(id: UUID, name: String, event: String) {
        guard !exclude(name) else { return }
        lastEvent[id] = (name: name, event: event)
    }
    
    mutating func removeEvents(id: UUID) {
        lastEvent.removeValue(forKey: id)
    }

    public var exclude: (_ name: String) -> Bool = { name in
        if name == "NavigationEnvPlaceholder" {
            return true
        }
        return false
    }
}
public var storeLifecycleLog = StoreLifecycleLog()

@MainActor
public protocol AnyStore: AnyViewModel {}

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
        
        // Disambiguate from Optional.none
        public static var noAction: Action {
            .none
        }
        
        var isPublish: Bool {
            switch self {
            case .publish:
                return true
            default:
                return false
            }
        }
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
    
    nonisolated public let id = UUID()
    public var name: String
    private var nestedLevel = 0
    
    public var environment: Environment?
    internal let reducer: Reducer
    private let taskManager = TaskManager()
    
    public var children: [String: any AnyViewModel] = [:]
    
    /// The default store key. The value is used for child stores and for logging.
    ///
    /// Uses the store namespace description as the default key because it's unlikely for a parent store to contain
    /// more than one child store of the same type.
    nonisolated
    public static var viewModelDefaultKey: String { "\(Nsp.self)" }
    
    public var logConfig = LogConfig()
    internal var logger: Logger {
        logConfig.logger
    }
    private var codeStringSnapshots: [ReducerSnapshotData] = []
    
    @Published public private(set) var state: State
    public private(set) var publishedValue = PassthroughSubject<PublishedValue, Cancel>()
    public private(set) var isCancelled = false
    public var hasRequest = false
    
    public init(_ initialValue: State, reducer: Reducer, env: Environment?) {
        self.name = Self.viewModelDefaultKey
        self.reducer = reducer
        self.state = initialValue
        self.environment = env

        if storeLifecycleLog.enabled {
            let name = Self.viewModelDefaultKey
            if storeLifecycleLog.debug {
                logger.debug("Allocated store \(name)\nid: \(self.id)")
            }
            storeLifecycleLog.addEvent(id: id, name: name, event: "Allocated")
        }
    }
    
    deinit {
        if storeLifecycleLog.enabled {
            let name = Self.viewModelDefaultKey
            if storeLifecycleLog.debug {
                logConfig.logger.debug("Deallocated store \(name)\nid: \(self.id)")
            }
            storeLifecycleLog.removeEvents(id: id)
        }
    }
    
    public convenience init(_ initialValue: State, reducer: Reducer)
    where Environment == Never, EffectAction == Never {
        self.init(initialValue, reducer: reducer, env: nil)
    }
    
    public convenience init(_ initialValue: State, reducer: Reducer) where Environment == Void {
        self.init(initialValue, reducer: reducer, env: ())
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
            taskManager.addTask { [weak self] in
                let action = await f()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard !isCancelled else { return }
                send(.code(action))
            }
            
        case .asyncActions(let f):
            taskManager.addTask { [weak self] in
                let actions = await f()
                guard let self else { return }
                for action in actions {
                    guard !Task.isCancelled else { return }
                    guard !isCancelled else { return }
                    send(.code(action))
                }
            }
            
        case .asyncActionSequence(let f):
            let actions = f()
            taskManager.addTask { [weak self] in
                for await action in actions {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard !isCancelled else { return }
                    send(.code(action))
                }
            }
            
        case .publisher(let publisher):
            taskManager.addTask { [weak self] in
                for await action in publisher.values {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard !isCancelled else { return }
                    send(.code(action))
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
            switch storeAction.action {
            case .cancel:
                return
            default:
                logger.warning("\nReceived action to a store that is already cancelled.")
                return
            }
        }
        if let logUserActions = logConfig.logUserActions {
            let actionName: String?
            let actionDetails: String?
            switch storeAction {
            case .user(let action), 
                 .code(let action) where action.isPublish:
                actionDetails = codeString(action)
                switch action {
                case .mutating(let mutatingAction, _, _):
                    actionName = caseName(mutatingAction)
                case .effect(let effectAction):
                    actionName = caseName(effectAction)
                case .cancel, .publish:
                    actionName = caseName(action)
                case .none:
                    actionName = nil
                }
            default:
                actionName = nil
                actionDetails = nil
            }
            if let actionName {
                logUserActions(actionName, actionDetails)
            }
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
            taskManager.cancelAllTasks()
            syncEffect = nil
            effect = nil
            environment = nil
            for child in children.values {
                child.cancel()
            }
            // don't remove child stores in case a child store view is rendered
            // after the child store is cancelled

            if storeLifecycleLog.enabled {
                let name = Self.viewModelDefaultKey
                if storeLifecycleLog.debug {
                    logger.debug("Cancelled store \(name)\nid: \(self.id)")
                }
                storeLifecycleLog.addEvent(id: id, name: name, event: "Cancelled")
            }

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

@MainActor
enum StoreUIContainers {
    private static var dict: [UUID: any StoreUIContainer] = [:]

    static func add(_ storeUI: any StoreUIContainer) {
        guard dict[storeUI.id] == nil else { return }
        dict[storeUI.id] = storeUI
    }
    
    static func remove(id: UUID) {
        dict.removeValue(forKey: id)
    }
    
    static func get<C: StoreUIContainer>(id: UUID) -> C? {
        guard let anyStoreUI = dict[id] else { return nil }
        guard let storeUI = anyStoreUI as? C else {
            assertionFailure()
            return nil
        }
        return storeUI
    }
}

// MARK: -  Snapshots and Logging

extension StateStore {
    public struct LogConfig {
        public var logState = false
        public var logActions = false
        public var saveSnapshots = false
        internal var logger: Logger
        public var logUserActions: ((_ actionName: String, _ actionDetails: String?) -> Void)?

        public init(
            logState: Bool = false,
            logActions: Bool = false,
            saveSnapshots: Bool = false,
            logger: Logger = Logger(subsystem: "ReducerStore", category: "\(StateStore.viewModelDefaultKey)"),
            logUserActions: ((String, String?) -> Void)? = nil
        ) {
            self.logState = logState
            self.logActions = logActions
            self.saveSnapshots = saveSnapshots
            self.logger = logger
            self.logUserActions = logUserActions
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
        let snapshotCollection = ReducerSnapshotCollection(title: Self.viewModelDefaultKey, snapshots: codeStringSnapshots)
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
