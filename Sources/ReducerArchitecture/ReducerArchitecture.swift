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
    
    @MainActor
    public static func reducer() -> Reducer where MutatingAction == Void, EffectAction == Never {
        .init { _, _ in .none }
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

public struct AsyncResult<T: Equatable>: Equatable {
    public var value: T? {
        didSet {
            count += 1
        }
    }

    public init() {}

    private(set) var count = 0
}

@MainActor
// Conformance to Hashable is necessary for SwiftUI navigation
public protocol AnyStore: AnyObject, Hashable, Identifiable {
    associatedtype PublishedValue

    var identifier: String { get }

    var value: AnyPublisher<PublishedValue, Cancel> { get }
    func publish(_ value: PublishedValue)
    func cancel()
}

public extension AnyStore {
    nonisolated
    var id: ObjectIdentifier {
        ObjectIdentifier(self)
    }
    
    var valueResult: AnyPublisher<Result<PublishedValue, Cancel>, Never> {
        value
            .map { .success($0) }
            .catch { Just(.failure($0)) }
            .eraseToAnyPublisher()
    }
    
    var throwingAsyncValues: AsyncThrowingPublisher<AnyPublisher<PublishedValue, Cancel>> {
        value.values
    }

    var asyncValues: AsyncPublisher<AnyPublisher<PublishedValue, Never>> {
        value.catch { _ in Empty<PublishedValue, Never>() }
            .eraseToAnyPublisher()
            .values
    }
    
    func get(callback: @escaping (PublishedValue) async -> Void) async {
        await asyncValues.get(callback: callback)
    }
    
    func getFirst(callback: @escaping (PublishedValue) async -> Void) async {
        if let firstValue = try? await value.first().async() {
            await callback(firstValue)
        }
    }
}

public enum StateStoreAction<Nsp: StoreNamespace> {
    case user(StateAction<Nsp>)
    case code(StateAction<Nsp>)
    
    var stateAction: StateAction<Nsp> {
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

extension StateStoreAction: Equatable where StateAction<Nsp>: Equatable {
}

extension StateStoreAction: Codable where StateAction<Nsp>: Codable {
}

public enum StateAction<Nsp: StoreNamespace> {
    case mutating(Nsp.MutatingAction, animated: Bool = false, Animation? = nil)
    case effect(Nsp.EffectAction)
    case publish(Nsp.PublishedValue)
    case cancel
    case none
}

extension StateAction: Equatable
where Nsp.MutatingAction: Equatable, Nsp.EffectAction: Equatable, Nsp.PublishedValue: Equatable {
}

extension StateAction: Codable
where Nsp.MutatingAction: Codable, Nsp.EffectAction: Codable, Nsp.PublishedValue: Codable {
    public enum Base: Codable {
        case mutating(Nsp.MutatingAction)
        case effect(Nsp.EffectAction)
        case publish(Nsp.PublishedValue)
        case cancel
        case none
        
        init(_ value: StateAction) {
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

public enum StateEffect<Nsp: StoreNamespace> {
    public typealias Action = StateAction<Nsp>
    
    case action(Action)
    case actions([Action])
    case asyncAction(() async throws -> Action?)
    case asyncActions(() async throws -> [Action])
    case asyncActionSequence(() -> AsyncStream<Action>)
    case publisher(AnyPublisher<Action, Never>)
    case none // cannot use Effect? in Reducer because it breaks the compiler
    
    init(_ e: SyncStateEffect<Nsp>) {
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

extension StateEffect where Action: Equatable {
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

public enum SyncStateEffect<Nsp: StoreNamespace> {
    public typealias Action = StateAction<Nsp>

    case action(Action)
    case actions([Action])
    case none // cannot use Effect? in Reducer because it breaks the compiler
}

extension SyncStateEffect: Codable where StateAction<Nsp>: Codable {
}

extension SyncStateEffect: Equatable where StateAction<Nsp>: Equatable {
}

public struct StateReducer<Nsp: StoreNamespace> {
    public typealias PublishedValue = Nsp.PublishedValue
    public typealias MutatingAction = Nsp.MutatingAction
    public typealias EffectAction = Nsp.EffectAction
    public typealias Environment = Nsp.StoreEnvironment
    public typealias Value = Nsp.StoreState
    
    public typealias Action = StateAction<Nsp>
    public typealias Effect = StateEffect<Nsp>
    public typealias SyncEffect = SyncStateEffect<Nsp>

    let run: (inout Value, MutatingAction) -> SyncEffect
    let effect: (Environment, Value, EffectAction) -> Effect

    public init(run: @escaping (inout Value, MutatingAction) -> SyncEffect, effect: @escaping (Environment, Value, EffectAction) -> Effect) {
        self.run = run
        self.effect = effect
    }
}

extension StateReducer where EffectAction == Never {
    @MainActor
    public init(_ run: @escaping (inout Value, MutatingAction) -> SyncEffect) {
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
    public typealias StoreAction = StateStoreAction<Nsp>
    public typealias PublishedValue = Nsp.PublishedValue
    public typealias MutatingAction = Nsp.MutatingAction
    public typealias EffectAction = Nsp.EffectAction
    public typealias Environment = Nsp.StoreEnvironment
    public typealias State = Nsp.StoreState
    
    public typealias Reducer = StateReducer<Nsp>
    public typealias ValuePublisher = AnyPublisher<PublishedValue, Cancel>

    public var identifier: String
    private var nestedLevel = 0

    public var environment: Environment?
    internal let reducer: Reducer
    private let tasksContainer = TasksContainer()

    public var logConfig = LogConfig()
    internal var logger: Logger
    private var codeStringSnapshots: [ReducerSnapshotData] = []
    
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
    
    @Published public private(set) var state: State
    private var publishedValue = PassthroughSubject<PublishedValue, Cancel>()

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

    public func addEffect(_ effect: Reducer.Effect) {
        switch effect {
        case .action(let action):
            send(.code(action))
            
        case .actions(let actions):
            for action in actions {
                send(.code(action))
            }
            
        case .asyncAction(let f):
            Task {
                await tasksContainer.addTask { [weak self] in
                    if let action = try await f() {
                        self?.send(.code(action))
                    }
                }
            }
            
        case .asyncActions(let f):
            Task {
                await tasksContainer.addTask { [weak self] in
                    let actions = try await f()
                    for action in actions {
                        self?.send(.code(action))
                    }
                }
            }
            
        case .asyncActionSequence(let f):
            let actions = f()
            Task {
                await tasksContainer.addTask { [weak self] in
                    for await action in actions {
                        try Task.checkCancellation()
                        self?.send(.code(action))
                    }
                }
            }
            
        case .publisher(let publisher):
            Task {
                await tasksContainer.addTask { [weak self] in
                    for await action in publisher.values {
                        try Task.checkCancellation()
                        self?.send(.code(action))
                    }
                }
            }
            
        case .none:
            break
        }
    }

    public func send(_ action: Reducer.Action) {
        send(.user(action))
    }
    
    private func send(_ storeAction: StoreAction) {
        var reducerInput = "\nreducer input:"
        if logConfig.logActions {
            reducerInput.append("\n\n\(codeString(storeAction))")
        }
        if logConfig.logState {
            reducerInput.append("\n\n\(codeString(state))")
        }
        if logConfig.logEnabled {
            reducerInput.append("\n\n")
            logger.debug("\(reducerInput)")
        }
        
        if logConfig.saveSnapshots {
            let snapshot: Snapshot = Snapshot.Input(date: .now, action: storeAction, state: state, nestedLevel: nestedLevel).snapshot
            codeStringSnapshots.append(snapshot.logData(errorLogger: logger))
        }
        
        let effect: Reducer.Effect?
        let syncEffect: Reducer.SyncEffect?
        switch storeAction.stateAction {
        case .mutating(let mutatingAction, let animate, let animation):
            if animate {
                syncEffect = withAnimation(animation ?? .default) { reducer.run(&state, mutatingAction) }
            }
            else {
                syncEffect = reducer.run(&state, mutatingAction)
            }
            effect = syncEffect.map { .init($0) }

            var reducerStateChange = "\nreducer state change:"
            if logConfig.logState {
                reducerStateChange.append("\n\n\(codeString(state))")
            }
            if logConfig.logEnabled {
                reducerStateChange.append("\n\n")
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
            syncEffect = nil
            effect = nil
            
        case .none:
            syncEffect = nil
            effect = nil
        }

        var reducerOutput = "\nreducer output:"
        if logConfig.logActions {
            reducerOutput.append("\n\n\(codeString(effect))")
        }
        if logConfig.logEnabled {
            reducerOutput.append("\n\n")
            logger.debug("\(reducerOutput)")
        }
        
        if logConfig.saveSnapshots {
            let snapshot = Snapshot.Output(
                date: .now,
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

    public func publish(_ value: PublishedValue) {
        send(.publish(value))
    }

    public func cancel() {
        send(.cancel)
    }
    
    // Hashable
    
    nonisolated
    public static func == (lhs: StateStore, rhs: StateStore) -> Bool {
        lhs === rhs
    }
    
    nonisolated
    public func hash(into hasher: inout Hasher) {
        ObjectIdentifier(self).hash(into: &hasher)
    }
    
    // Mark: - Logging
    
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
            let effect: Reducer.Effect?
            let syncEffect: Reducer.SyncEffect?
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
                switch input.action.stateAction {
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
}
