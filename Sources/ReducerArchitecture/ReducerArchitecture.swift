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
// Conformance to Hashable is necessary for SwiftUI navigation
public protocol AnyStore: AnyObject, Hashable, Identifiable {
    associatedtype PublishedValue

    nonisolated var id: UUID { get }
    nonisolated var name: String { get }
    var isCancelled: Bool { get }
    var publishedValue: PassthroughSubject<PublishedValue, Cancel> { get }
    func publish(_ value: PublishedValue)
    func cancel()
    
    /// Indicates whether there is request for a published value.
    ///
    /// Useful for testing navigation flows.
    var hasRequest: Bool { get set }
    
    nonisolated
    static var storeDefaultKey: String { get }
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
        defer { cancel() }
        return try await value.first().async()
    }
    
    /// A convenience API to avoid a race condition between the code that needs a first value
    /// and the code that provides it.
    func getRequest() async -> Void {
        while !hasRequest {
            await Task.yield()
        }
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
    
    var isCancelledPublisher: AnyPublisher<Void, Never> {
        publishedValue
            .map { _ in false }
            .replaceError(with: true)
            .filter { $0 }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    var isStateStore: Bool {
        "\(type(of: self))".hasPrefix("StateStore<")
    }
}

// Identifiable, Hashable
public extension AnyStore {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
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
    
    private var children: [String: any AnyStore] = [:]
    
    /// The default store key. The value is used for child stores and for logging.
    ///
    /// Uses the store namespace description as the default key because it's unlikely for a parent store to contain
    /// more than one child store of the same type.
    nonisolated
    public static var storeDefaultKey: String { "\(Nsp.self)" }
    
    /// Adds a child to the store. The store must not already contain a child with the provided `key`.
    public func addChild<T>(_ child: StateStore<T>, key: String = StateStore<T>.storeDefaultKey) {
        assert(children[key] == nil)
        objectWillChange.send()
        children[key] = child
    }
    
    /// Removes a child from the store. If not `nil`, `child` must be a child of the store
    /// - Parameters:
    ///   - child: The child store to be removed.
    ///   - delay: Whether to delay the actual removal until the next UI update.
    ///
    ///  `delay` is useful to allow animated transitions for removing the UI for `child`.
    public func removeChild(_ child: (any AnyStore)?, delay: Bool = true) {
        guard let child else { return }
        objectWillChange.send()
        child.cancel()
        if delay {
            DispatchQueue.main.async {
                self.removeChildImpl(child)
            }
        }
        else {
            removeChildImpl(child)
        }
    }
    
    private func removeChildImpl(_ child: (any AnyStore)?) {
        guard let child else { return }
        assert(child.isCancelled)
        guard let index = children.firstIndex(where: { $1 === child }) else { return }
        children.remove(at: index)
    }

    /// Adds a child to the store. If the store already contains a child with the provided `key`, the child store
    /// expression is not evaluated.
    public func addChildIfNeeded<T>(_ child: @autoclosure () -> StateStore<T>, key: String = StateStore<T>.storeDefaultKey) {
        if children[key] == nil {
            addChild(child())
        }
    }

    /// Returns a child store with a specific `key`.
    ///
    /// A child store should not be saved in `@State` or `@ObjectState` of a view because that creates a retain cycle:
    /// View State -> Store -> Store Environmemnt -> View State or
    /// Child View State -> Child Store -> Child Store Environment -> Child View State
    /// The retain cycle is there even with @ObservedObject because then SwiftUI View State still adds a reference to
    /// the store.
    ///
    /// The only way to break the retain cycle is to set the store environment to nil by cancelling the store. (Setting
    /// the store environment to nil directly is dangerous because the store might still receive messages after that but
    /// when the store is cancelled those messages are automatically ignored.)
    ///
    /// This is done automatically when a store is popped from the navigation stack or when its sheet is dismissed.
    /// However, if a child store is not retained by the store itself and is saved via the view state instead, the child
    /// store is not cancelled. Using the `child` APIs allows the child store to be cancelled automatically when its
    /// parent store is cancelled manually or as a result of going out of scope.
    ///
    /// Example:
    /// ```Swift
    /// private var childStore: ChildStoreNsp.Store { store.child()! }
    /// 
    /// public init(store: Store) {
    ///    self.store = store
    ///    store.addChildIfNeeded(ChildStoreNsp.store())
    /// }
    /// ```
    public func child<T>(key: String = StateStore<T>.storeDefaultKey) -> StateStore<T>? {
        children[key] as? StateStore<T>
    }

    public func anyChild(key: String) -> (any AnyStore)? {
        children[key]
    }

    /// Runs a child store until it produces the first value
    public func run<T>(_ child: StateStore<T>, key: String = StateStore<T>.storeDefaultKey) async throws -> T.PublishedValue {
        addChild(child, key: key)
        defer { removeChild(child) }
        return try await child.firstValue()
    }

    public var logConfig = LogConfig()
    internal var logger: Logger {
        logConfig.logger
    }

    @Published public private(set) var state: State
    public private(set) var publishedValue = PassthroughSubject<PublishedValue, Cancel>()
    public private(set) var isCancelled = false
    public var hasRequest = false
    
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
        
        if let e = effect {
            addEffect(e)
        }
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

extension StateStore {
    public struct LogConfig {
        public var logState = false
        public var logActions = false
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
}
