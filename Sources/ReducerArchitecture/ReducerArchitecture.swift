//
//  ReducerArchitecture.swift
//  Rocket Insights
//
//  Created by Ilya Belenkiy on 03/30/21.
//  Copyright © 2021 Rocket Insights. All rights reserved.
//

import FoundationEx
#if canImport(AsyncNavigation)
@_exported import AsyncNavigation
#endif
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

private func apply<T>(_ animation: Animation? = nil, _ body: () -> T) -> T {
    if let animation {
        return withAnimation(animation, body)
    }
    else {
        return body()
    }
}

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
    public private(set) var lastEvent: [UUID: (name: String, event: String)] = [:]
    
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
public protocol AnyStore: BasicViewModel {
    func anyChild(key: String) -> (any AnyStore)?
}

extension AnyStore {
    public func anyChild(key: String) -> (any AnyStore)? {
        let viewModel: (any BasicViewModel)? = (self as (any BasicViewModel)).anyChild(key: key)
        return viewModel as? any AnyStore
    }
}

// StateStore should not be subclassed because of a bug in SwiftUI
@MainActor
public final class StateStore<Nsp: StoreNamespace>: AnyStore {
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
        /// Swift doesn't allow default arguments in closures.
        /// This type provides a workaround, making it possible to call the wrapped callback
        /// with only the action, ommiting animation if it's nil.
        public struct AsyncActionCallback {
            private let callback: (Action, Animation?) -> Void

            init(_ callback: @escaping (Action, Animation?) -> Void) {
                self.callback = callback
            }

            public func callAsFunction(_ action: Action) {
                callback(action, nil)
            }

            public func callAsFunction(_ action: Action, _ animation: Animation?) {
                callback(action, animation)
            }
        }

        case action(Action, Animation? = nil)
        case actions([Action], Animation? = nil)
        case asyncAction(Animation? = nil, () async -> Action)
        case asyncActionLatest(key: String, Animation? = nil, () async -> Action)
        case asyncActions(Animation? = nil, () async -> [Action])
        case asyncActionSequence((_ callback: AsyncActionCallback) async -> Void)
        case publisher(AnyPublisher<Action, Never>, Animation? = nil)
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
    nonisolated(unsafe) public var name: String
    private var nestedLevel = 0
    
    public var environment: Environment?
    internal let reducer: Reducer
    private let taskManager = TaskManager()
    
    public var children: [String: any BasicViewModel] = [:]

    public var logConfig = LogConfig()
    internal var logger: Logger {
        logConfig.logger
    }
    private var codeStringSnapshots: [ReducerSnapshotData] = []

    @Published public private(set) var state: State
    public private(set) var publishedValue = PassthroughSubject<PublishedValue, Cancel>()
    public private(set) var isCancelled = false
    public var hasRequest = false

    nonisolated
    public static var storeDefaultKey: String {
        String(describing: Nsp.self)
    }

    public init(_ initialValue: State, reducer: Reducer, env: Environment?) {
        self.name = Self.storeDefaultKey
        self.reducer = reducer
        self.state = initialValue
        self.environment = env

        if storeLifecycleLog.enabled {
            let name = Self.storeDefaultKey
            if storeLifecycleLog.debug {
                logger.debug("Allocated store \(name)\nid: \(self.id)")
            }
            storeLifecycleLog.addEvent(id: id, name: name, event: "Allocated")
        }
    }
    
    deinit {
        if storeLifecycleLog.enabled {
            let name = Self.storeDefaultKey
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
        case let .action(action, anim):
            send(.code(action), anim)

        case let .actions(actions, anim):
            for action in actions {
                send(.code(action), anim)
            }
            
        case let .asyncAction(anim, f):
            taskManager.addTask { [weak self] in
                let action = await f()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard !isCancelled else { return }
                send(.code(action), anim)
            }

        case let .asyncActionLatest(key, anim, f):
            taskManager.addTask(cancellingPreviousWithKey: key) { [weak self] in
                let action = await f()
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard !isCancelled else { return }
                send(.code(action), anim)
            }

        case .asyncActions(let anim, let f):
            taskManager.addTask { [weak self] in
                let actions = await f()
                guard let self else { return }
                for action in actions {
                    guard !Task.isCancelled else { return }
                    guard !isCancelled else { return }
                    send(.code(action), anim)
                }
            }
            
        case .asyncActionSequence(let f):
            let stream = AsyncStream<(Action, Animation?)> { continuation in
                let callback = Effect.AsyncActionCallback { action, anim in
                    guard !Task.isCancelled else { return }
                    continuation.yield((action, anim))
                }

                taskManager.addTask {
                    await f(callback)
                    continuation.finish()
                }
            }
            taskManager.addTask { [weak self] in
                for await (action, anim) in stream {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard !isCancelled else { return }
                    send(.code(action), anim)
                }
            }

        case let .publisher(publisher, anim):
            taskManager.addTask { [weak self] in
                for await action in publisher.values {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    guard !isCancelled else { return }
                    send(.code(action), anim)
                }
            }
            
        case .none:
            break
        }
    }
    
    public func send(_ action: Action, _ anim: Animation? = nil, file: String = #fileID, line: Int = #line) {
        send(.user(action), anim, file: file, line: line)
    }
    
    private func send(_ storeAction: StoreAction, _ anim: Animation?, file: String = #fileID, line: Int = #line) {
        apply(anim) {
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
            if logConfig.logActionCallSite {
                reducerInput.append("\nfile: \(file), line: \(line)")
            }
            if logConfig.logActions {
                reducerInput.append("\n->\n\(codeString(storeAction))")
            }
            if logConfig.logState {
                reducerInput.append("\n->\n\(codeString(state))")
            }
            if logConfig.logEnabled {
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
                _publish(value)
                syncEffect = nil
                effect = nil

            case .cancel:
                _cancel()
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
                    let name = Self.storeDefaultKey
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

    public func publish(_ value: PublishedValue, file: String = #fileID, line: Int = #line) {
        send(.publish(value), file: file, line: line)
    }

    public func cancel(file: String = #fileID, line: Int = #line) {
        send(.cancel, file: file, line: line)
    }
}

extension StateStore.Reducer where Nsp.EffectAction == Never {
    @MainActor
    public init(_ run: @escaping (inout Value, Nsp.MutatingAction) -> StateStore.SyncEffect) {
        self = StateStore.Reducer(run: run, effect: { _, _, effectAction in .none })
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
        animation: Animation? = nil,
        compare: @escaping (OtherValue, OtherValue) -> Bool
    ) {
        addEffect(
            .publisher(
                otherStore
                    .distinctValues(on: keyPath, compare: compare)
                    .compactMap { action($0) }
                    .eraseToAnyPublisher(),
                animation
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
        with action: @escaping (OtherNsp.PublishedValue) -> Action,
        animation: Animation? = nil
    ) {
        addEffect(
            .publisher(
                otherStore.value.map { action($0) }
                    .catch { _ in Just(.cancel) }
                    .eraseToAnyPublisher(),
                animation
            )
        )
    }
}

extension StateStore {
    public struct LogConfig {
        public var logState = false
        public var logActions = false
        public var logActionCallSite = false
        public var saveSnapshots = false
        public var snapshotsFilename: String? = nil

        public var logEnabled: Bool {
            logState || logActions || logActionCallSite
        }

        internal var logger: Logger
        public var logUserActions: ((_ actionName: String, _ actionDetails: String?) -> Void)?

        public init(
            logState: Bool = false,
            logActions: Bool = false,
            logger: Logger = Logger(subsystem: "ReducerStore", category: "\(StateStore.storeDefaultKey)"),
            logUserActions: ((String, String?) -> Void)? = nil
        ) {
            self.logState = logState
            self.logActions = logActions
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

        public func logData(errorLogger logger: Logger) -> ReducerSnapshotData {
            switch self {
            case .input(let input):
                return ReducerSnapshotData.Input(
                    date: input.date,
                    action: codeString(input.action),
                    state: propertyCodeStrings(input.state),
                    nestedLevel: input.nestedLevel
                )
                .snapshotData

            case .stateChange(let stateChange):
                return ReducerSnapshotData.StateChange(
                    date: stateChange.date,
                    state: propertyCodeStrings(stateChange.state),
                    nestedLevel: stateChange.nestedLevel
                )
                .snapshotData

            case .output(let output):
                return ReducerSnapshotData.Output(
                    date: output.date,
                    effect: codeString(output.effect),
                    state: propertyCodeStrings(output.state),
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
        let title = logConfig.snapshotsFilename ?? name
        let snapshotCollection = ReducerSnapshotCollection(title: title, snapshots: codeStringSnapshots)
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

