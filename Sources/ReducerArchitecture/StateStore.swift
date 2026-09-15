//  StateStore.swift
//  Created by Ilya Belenkiy on 03/30/21.

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
import AsyncAlgorithms
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
    associatedtype PublishedValue: Sendable

    @MainActor
    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> StateStore<Self>.SyncEffect

    @MainActor
    static func runEffect(_ env: StoreEnvironment, _ state: StoreState, _ action: EffectAction) -> StateStore<Self>.Effect
}

extension StoreNamespace {
    public typealias Nsp = Self
    public typealias Store = StateStore<Self>
}

extension StoreNamespace
where EffectAction == Never {
    @MainActor
    public static func runEffect(_ env: StoreEnvironment, _ state: StoreState, _ action: EffectAction) -> StateStore<Self>.Effect {
        fatalError("runEffect should never be called when EffectAction == Never")
    }
}

extension StoreNamespace
where MutatingAction == Void, EffectAction == Never {
    @MainActor
    public static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> StateStore<Self>.SyncEffect {
        .none
    }
}

#if DEBUG
public enum LiveTraceMode: Equatable, Sendable {
    case selfOnly
    case selfAndChildren
}
#endif

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
        case none // cannot use Effect? in reducer callbacks because it breaks the compiler
    }
    
    public enum Effect {
        /// Swift doesn't allow default arguments in closures.
        /// This type provides a workaround, making it possible to call the wrapped callback
        /// with only the action, ommiting animation if it's nil.
        @MainActor
        public struct AsyncActionCallback {
            private let callback: (Action, Animation?, String, Int) -> Void

            init(_ callback: @escaping (Action, Animation?, String, Int) -> Void) {
                self.callback = callback
            }

            public func callAsFunction(_ action: Action, file: String = #fileID, line: Int = #line) {
                callback(action, nil, file, line)
            }

            public func callAsFunction(
                _ action: Action,
                _ animation: Animation?,
                file: String = #fileID,
                line: Int = #line
            ) {
                callback(action, animation, file, line)
            }
        }

        case action(Action, Animation? = nil)
        case actions([Action], Animation? = nil)
        case asyncAction(Animation? = nil, @MainActor () async -> Action)
        case asyncActionLatest(key: String, Animation? = nil, @MainActor () async -> Action)
        case asyncActions(Animation? = nil, @MainActor () async -> [Action])
        case asyncActionSequence(@MainActor (_ callback: AsyncActionCallback) async -> Void)
        case asyncActionSequenceLatest(key: String, @MainActor (_ callback: AsyncActionCallback) async -> Void)
        case asyncSequence(any AsyncSequence<Action, Never>, Animation? = nil)
        case publisher(AnyPublisher<Action, Never>, Animation? = nil)
        case none // cannot use Effect? in reducer callbacks because it breaks the compiler

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
    
    nonisolated public let id = UUID()
    nonisolated(unsafe) public var name: String
    var nestedLevel = 0

    public var environment: Environment?
    private let taskManager = TaskManager()

    public var children: [String: any BasicViewModel] = [:]

    public var logConfig = LogConfig() {
        didSet {
#if DEBUG
            handleLogConfigDidChange(previousConfig: oldValue)
#endif
        }
    }
    internal var logger: Logger {
        logConfig.logger
    }
#if DEBUG
    /// Recorder for one store's live trace stream.
    ///
    /// The recorder is created on first traced action/effect and reused across subsequent sends
    /// so ids, open actions, open effects, and batch sequencing stay stable for the session.
    var isSessionGraphTracingActive = false
    var sessionGraphRecorder: SessionGraphRecorder?
    var liveTraceMetadata: LiveTraceStoreMetadata?
    var liveTraceHandler: LiveTraceHandler?
    var liveTraceParentStoreInstanceID: String?
    var liveTraceChildKeyInParentStore: String?
#endif

    @Published public private(set) var state: State {
        didSet { stateValues.send(state) }
    }
    private let stateValues: MainActorValueSource<State>
    public let publishedValue = PublishedValues<PublishedValue>()
    @Published public private(set) var isCancelled = false

    nonisolated
    public static var storeDefaultKey: String {
        String(describing: Nsp.self)
    }

    public init(_ initialValue: State, env: Environment?) {
        self.name = Self.storeDefaultKey
#if DEBUG
        self.isSessionGraphTracingActive = false
        self.sessionGraphRecorder = nil
        self.liveTraceMetadata = nil
        self.liveTraceHandler = nil
        self.liveTraceParentStoreInstanceID = nil
        self.liveTraceChildKeyInParentStore = nil
#endif
        self.state = initialValue
        self.stateValues = MainActorValueSource(initialValue: initialValue)
        self.environment = env

#if DEBUG
        if LiveTraceConfig.shared.traceAllStores {
            let previousConfig = logConfig
            logConfig.liveTraceEnabled = .selfAndChildren
            handleLogConfigDidChange(previousConfig: previousConfig)
        }
#endif
    }

#if compiler(<6.4)
    // Avoid the generic isolated-deinit optimizer crash: https://github.com/swiftlang/swift/issues/87462
    @_optimize(none)
#endif
    isolated deinit {
        publishedValue.finish()
        stateValues.finish()
#if DEBUG
        Self.notifyLiveTraceStoreEndedOnDeinit(
            metadata: liveTraceMetadata,
            handler: liveTraceHandler,
            logger: logConfig.logger
        )
#endif
    }

    private static func consumeActions<Iterator: AsyncIteratorProtocol>(
        iterator: Iterator,
        storeProvider: @escaping () -> StateStore?,
        mapToAction: (Iterator.Element) -> (Action, Animation?),
        callSite: ((Iterator.Element) -> (String?, Int?))? = nil,
        trace: SessionTraceSendContext = .system
    ) async where Iterator.Failure == Never {
        var iterator = iterator
        await withTaskGroup(of: Void.self) { group in
            while let element = await iterator.next(isolation: MainActor.shared) {
                guard !Task.isCancelled else { return }
                guard let store = storeProvider() else { return }
                guard !store.isCancelled else { return }
                let (action, anim) = mapToAction(element)
                let (file, line) = callSite?(element) ?? (nil, nil)
                if let task = store.send(
                    .code(action),
                    anim,
                    trace: trace,
                    file: file,
                    line: line
                ) {
                    group.addTask {
                        await task.value
                    }
                }
            }
        }
    }

    private static func runAsyncAction(
        _ asyncAction: @MainActor () async -> Action,
        animation: Animation?,
        storeProvider: @escaping () -> StateStore?,
        trace: SessionTraceSendContext = .system
    ) async {
        let action = await asyncAction()
        guard !Task.isCancelled else { return }
        let task: Task<Void, Never>?
        // Release the store before waiting for a nested effect, which may be a long-lived observation.
        do {
            guard let store = storeProvider() else { return }
            guard !store.isCancelled else { return }
            task = store.send(.code(action), animation, trace: trace)
        }
        await task?.value
    }

    private static func addAsyncActionTask(
        taskManager: TaskManager,
        cancellingPreviousWithKey key: String? = nil,
        animation: Animation?,
        asyncAction: @escaping @MainActor () async -> Action,
        storeProvider: @escaping () -> StateStore?,
        trace: SessionTraceSendContext = .system
    ) -> Task<Void, Never> {
        taskManager.addTask(cancellingPreviousWithKey: key) {
            await runAsyncAction(
                asyncAction,
                animation: animation,
                storeProvider: storeProvider,
                trace: trace
            )
        }
    }

    private static func addAsyncActionSequenceTask(
        taskManager: TaskManager,
        cancellingPreviousWithKey key: String? = nil,
        asyncActionSequence: @escaping @MainActor (_ callback: Effect.AsyncActionCallback) async -> Void,
        storeProvider: @escaping () -> StateStore?,
        trace: SessionTraceSendContext = .system
    ) -> Task<Void, Never> {
        let source = MainActorValueSource<(Action, Animation?, String, Int)>()
        let iterator = source.values.makeAsyncIterator()

        let producer = taskManager.addTask(cancellingPreviousWithKey: key.map { "\($0)-producer" }) {
            await withTaskCancellationHandler(
                operation: {
                    let callback = Effect.AsyncActionCallback { action, anim, file, line in
                        guard !Task.isCancelled else { return }
                        source.send((action, anim, file, line))
                    }
                    await asyncActionSequence(callback)
                    source.finish()
                },
                onCancel: {
                    Task { @MainActor in source.finish() }
                }
            )
        }

        let consumer = taskManager.addTask(cancellingPreviousWithKey: key.map { "\($0)-consumer" }) {
            await consumeActions(
                iterator: iterator,
                storeProvider: storeProvider,
                mapToAction: { action, anim, _, _ in
                    (action, anim)
                },
                callSite: { _, _, file, line in
                    (file, line)
                },
                trace: trace
            )
        }

        return Task {
            await withTaskCancellationHandler(
                operation: {
                    await producer.value
                    await consumer.value
                },
                onCancel: {
                    producer.cancel()
                    consumer.cancel()
                }
            )
        }
    }

    @discardableResult
    public func addEffect(_ effect: Effect) -> Task<Void, Never>? {
        addEffect(
            effect,
            trace: .init(
                startedByActionID: nil,
                inheritedAnimationGroupID: nil
            )
        )
    }

    @discardableResult
    fileprivate func addEffect(
        _ effect: Effect,
        trace: SessionTraceEffectContext,
        file: String? = nil,
        line: Int? = nil,
        dispatchingSyncEffect: Bool = false
    ) -> Task<Void, Never>? {
        let effectTrace = beginSessionTraceEffectIfNeeded(
            effect,
            trace: trace,
            dispatchingSyncEffect: dispatchingSyncEffect
        )
        let effectActionTrace = sessionTraceContextForEffectAction(
            effectID: effectTrace.effectID,
            animationGroupID: effectTrace.animationGroupID,
            containingBatchID: nil
        )
        switch effect {
        case let .action(action, anim):
            let traceParameters = sessionTraceParametersForEffectAction(
                dispatchingSyncEffect: dispatchingSyncEffect,
                trace: trace,
                effectID: effectTrace.effectID,
                animationGroupID: effectTrace.animationGroupID,
                file: file,
                line: line,
                containingBatchID: nil
            )
            return send(
                .code(action),
                anim,
                trace: traceParameters.trace,
                file: traceParameters.file,
                line: traceParameters.line
            )

        case let .actions(actions, anim):
            let traceParameters = sessionTraceBatchParametersForEffectActions(
                dispatchingSyncEffect: dispatchingSyncEffect,
                trace: trace,
                effectID: effectTrace.effectID,
                animationGroupID: effectTrace.animationGroupID,
                actionCount: actions.count,
                file: file,
                line: line
            )
            let tasks = actions.compactMap { action in
                send(
                    .code(action),
                    anim,
                    trace: traceParameters.trace,
                    file: traceParameters.file,
                    line: traceParameters.line
                )
            }
            if tasks.isEmpty {
                return nil
            }
            else {
                return Task {
                    for task in tasks {
                        await task.value
                    }
                }
            }

        case let .asyncAction(anim, f):
            if dispatchingSyncEffect {
                assertionFailure()
            }
            return Self.addAsyncActionTask(
                taskManager: taskManager,
                animation: anim,
                asyncAction: f,
                storeProvider: { [weak self] in self },
                trace: effectActionTrace
            )

        case let .asyncActionLatest(key, anim, f):
            if dispatchingSyncEffect {
                assertionFailure()
            }
            return Self.addAsyncActionTask(
                taskManager: taskManager,
                cancellingPreviousWithKey: key,
                animation: anim,
                asyncAction: f,
                storeProvider: { [weak self] in self },
                trace: effectActionTrace
            )

        case .asyncActions(let anim, let f):
            if dispatchingSyncEffect {
                assertionFailure()
            }
            return taskManager.addTask { [weak self] in
                let actions = await f()
                let traceParameters: SessionTraceSendContext
                do { // capture store temporarily to get trace parameters
                    guard let store = self else { return }
                    guard !store.isCancelled else { return }
                    traceParameters = store.sessionTraceParametersForAsyncEffectActions(
                        effectID: effectTrace.effectID,
                        animationGroupID: effectTrace.animationGroupID,
                        actionCount: actions.count
                    )
                }

                await withTaskGroup(of: Void.self) { group in
                    for action in actions {
                        guard !Task.isCancelled else { return }
                        guard let self else { return }
                        guard !self.isCancelled else { return }
                        if let task = self.send(
                            .code(action),
                            anim,
                            trace: traceParameters
                        ) {
                            group.addTask {
                                await task.value
                            }
                        }
                    }
                }
            }

        case .asyncActionSequence(let f):
            if dispatchingSyncEffect {
                assertionFailure()
            }
            return Self.addAsyncActionSequenceTask(
                taskManager: taskManager,
                asyncActionSequence: f,
                storeProvider: { [weak self] in self },
                trace: effectActionTrace
            )

        case let .asyncActionSequenceLatest(key, f):
            if dispatchingSyncEffect {
                assertionFailure()
            }
            return Self.addAsyncActionSequenceTask(
                taskManager: taskManager,
                cancellingPreviousWithKey: key,
                asyncActionSequence: f,
                storeProvider: { [weak self] in self },
                trace: effectActionTrace
            )

        case let .asyncSequence(sequence, anim):
            if dispatchingSyncEffect {
                assertionFailure()
            }
            guard !isCancelled else { return nil }
            // Register before scheduling so values sent immediately after addEffect are buffered.
            let iterator = sequence.makeAsyncIterator()
            return taskManager.addTask { [weak self] in
                await Self.consumeActions(
                    iterator: iterator,
                    storeProvider: { [weak self] in self },
                    mapToAction: { ($0, anim) },
                    trace: effectActionTrace
                )
            }

        case let .publisher(publisher, anim):
            if dispatchingSyncEffect {
                assertionFailure()
            }
            let source = MainActorValueSource<Action>()
            let iterator = source.values.makeAsyncIterator()
            return taskManager.addTask { [weak self] in
                // Combine may emit on any queue. Deliver to the main actor before handling non-Sendable actions.
                let cancellable = publisher.receive(on: DispatchQueue.main).sink(
                    receiveCompletion: { _ in
                        source.finish()
                    },
                    receiveValue: { action in
                        source.send(action)
                    }
                )
                let cancelSubscription: @MainActor @Sendable () -> Void = { cancellable.cancel() }

                await withTaskCancellationHandler(
                    operation: {
                        await Self.consumeActions(
                            iterator: iterator,
                            storeProvider: { [weak self] in self },
                            mapToAction: { ($0, anim) },
                            trace: effectActionTrace
                        )
                        cancellable.cancel()
                    },
                    onCancel: {
                        // Cancellation handlers can run on any executor; subscriptions stay on the main actor.
                        Task { @MainActor in
                            cancelSubscription()
                            source.finish()
                        }
                    }
                )
            }

        case .none:
            return nil
        }
    }

    @discardableResult
    public func send(_ action: Action, _ anim: Animation? = nil, file: String = #fileID, line: Int = #line) -> Task<Void, Never>? {
        send(
            .user(action),
            anim,
            trace: .user,
            file: file,
            line: line
        )
    }

    private func send(
        _ storeAction: StoreAction,
        _ anim: Animation?,
        trace: SessionTraceSendContext = .system,
        file: String? = #fileID,
        line: Int? = #line
    ) -> Task<Void, Never>? {
        apply(anim) { () -> Task<Void, Never>? in
            guard !isCancelled else {
                switch storeAction.action {
                case .cancel:
                    return nil
                default:
                    logger.warning("\nReceived action to a store that is already cancelled.")
                    return nil
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
            if logConfig.logActionCallSite,
               let file,
               let line {
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

            let shouldRecordActionTrace = shouldRecordSessionTraceAction(storeAction.action)
            let actionTrace: SessionTraceActionScope
            if shouldRecordActionTrace {
                actionTrace = beginSessionTraceActionIfNeeded(
                    storeAction: storeAction,
                    animation: anim,
                    trace: trace,
                    file: file,
                    line: line
                )
            }
            else {
                actionTrace = .disabled
            }
            var effect: Effect? = nil
            var syncEffect: SyncEffect? = nil
            defer {
                if shouldRecordActionTrace {
                    finishSessionTraceActionIfNeeded(actionTrace, outputEffect: effect)
                }
            }
            switch storeAction.action {
            case .mutating(let mutatingAction, let animate, let animation):
                if animate {
                    syncEffect = withAnimation(animation ?? .default) {
                        Nsp.reduce(&state, mutatingAction)
                    }
                }
                else {
                    syncEffect = Nsp.reduce(&state, mutatingAction)
                }
                effect = syncEffect.map { .init($0) }
                if shouldRecordActionTrace {
                    recordSessionTraceMutationIfNeeded(actionTrace)
                }

                if logConfig.logState {
                    var reducerStateChange = "\n<-"
                    reducerStateChange.append("\n\(codeString(state))")
                    logger.debug("\(reducerStateChange)")
                }

            case .effect(let effectAction):
                guard let env = environment else {
                    assertionFailure()
                    return nil
                }

                // When executing an effect, the environment may send more messages to the store while
                // inside this call
                nestedLevel += 1
                syncEffect = nil
                effect = Nsp.runEffect(env, state, effectAction)
                nestedLevel -= 1

            case .publish(let value):
                _publish(value)
                syncEffect = nil
                effect = nil

            case .cancel:
                _cancel()
                isCancelled = true
                stateValues.finish()
                taskManager.cancelAllTasks()
                if shouldRecordActionTrace {
                    cancelAllActiveSessionTraceEffectsIfNeeded(actionTrace)
                }
                syncEffect = nil
                effect = nil
                environment = nil
                for child in children.values {
                    child.cancel()
                }
                // don't remove child stores in case a child store view is rendered
                // after the child store is cancelled

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
                return addEffect(
                    e,
                    trace: .init(
                        startedByActionID: actionTrace.actionID,
                        inheritedAnimationGroupID: actionTrace.animationGroupID
                    ),
                    file: file,
                    line: line,
                    dispatchingSyncEffect: syncEffect != nil
                )
            }
            else {
                return nil
            }
        }
    }

    // Must keep this exact signature to conform to `BasicViewModel`.
    // Adding `file/line` here would not satisfy the protocol requirement.
    public func publish(_ value: PublishedValue) {
        send(.publish(value))
    }

    // Must keep this exact signature to conform to `BasicViewModel`.
    // Adding `file/line` here would not satisfy the protocol requirement.
    public func cancel() {
        send(.cancel)
    }
}

public extension StateStore {
    func addChild<VM: BasicViewModel>(_ child: VM, key: String = VM.viewModelDefaultKey) {
        addChild(child, key: key) { child, key in
#if DEBUG
            self.configureLiveTraceForAddedChildIfNeeded(child, key: key)
#endif
        }
    }

    func addChildIfNeeded<VM: BasicViewModel>(
        _ child: @autoclosure () -> VM,
        key: String = VM.viewModelDefaultKey
    ) {
        addChildIfNeeded(child(), key: key) { child, key in
#if DEBUG
            self.configureLiveTraceForAddedChildIfNeeded(child, key: key)
#endif
        }
    }

    func run<VM: BasicViewModel>(
        _ child: VM,
        key: String = VM.viewModelDefaultKey
    ) async throws -> VM.PublishedValue {
        try await run(child, key: key) { child, key in
#if DEBUG
            self.configureLiveTraceForAddedChildIfNeeded(child, key: key)
#endif
        }
    }
}

public extension StateStore {
    func values<Value>(on keyPath: KeyPath<State, Value>) -> AnyPublisher<Value, Never> {
        if isCancelled {
            return Empty().eraseToAnyPublisher()
        }
        
        return $state
            .map(keyPath)
            .prefix(untilOutputFrom: $isCancelled.filter { $0 })
            .eraseToAnyPublisher()
    }
    
    /// Current state followed by every mutation, buffered separately for each main-actor iterator.
    func asyncValues<Value>(on keyPath: KeyPath<State, Value>) -> MainActorSequence<Value> {
        stateValues.values.map { $0[keyPath: keyPath] }
    }

    func values<Value>(on keyPath: KeyPath<State, Value>) -> MainActorSequence<Value> {
        asyncValues(on: keyPath)
    }

    func updates<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool) -> AnyPublisher<Value, Never> {
            values(on: keyPath)
                .removeDuplicates(by: compare)
                .dropFirst()
                .eraseToAnyPublisher()
        }
    
    func updates<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> AnyPublisher<Value, Never> {
        updates(on: keyPath, compare: { $0 == $1 })
    }

    func updates<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool
    ) -> MainActorSequence<Value> {
        let values: MainActorSequence<Value> = distinctValues(on: keyPath, compare: compare)
        let updates = values.dropFirst()
        return MainActorSequence {
            var iterator = updates.makeAsyncIterator()
            return { await iterator.next(isolation: MainActor.shared) }
        }
    }

    func updates<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> MainActorSequence<Value> {
        updates(on: keyPath, compare: { $0 == $1 })
    }
    
    func distinctValues<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool) -> AnyPublisher<Value, Never> {
            values(on: keyPath)
                .removeDuplicates(by: compare)
                .eraseToAnyPublisher()
        }
    
    func distinctValues<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> AnyPublisher<Value, Never> {
        distinctValues(on: keyPath, compare: { $0 == $1 })
    }

    // AsyncAlgorithms' removeDuplicates accepts a nonisolated @Sendable async predicate.
    // The store's MainActor isolation does not extend into that operator, so passing our
    // MainActor comparison requires Sendable arguments. This MainActor class is implicitly
    // Sendable while access to its payload and its destruction remain on MainActor.
    // Unlike PublishedValue, observed state values do not have to conform to Sendable.
    @MainActor
    private final class ObservedStateValue<Value> {
        let value: Value
        init(_ value: Value) { self.value = value }
#if compiler(<6.4)
        // Avoid the generic isolated-deinit optimizer crash: https://github.com/swiftlang/swift/issues/87462
        @_optimize(none)
#endif
        isolated deinit {}
    }

    /// Current value followed by distinct changes. Values and comparisons remain on the main actor.
    func distinctValues<Value>(
        on keyPath: KeyPath<State, Value>,
        compare: @escaping (Value, Value) -> Bool
    ) -> MainActorSequence<Value> {
        let compareValues: @MainActor @Sendable (ObservedStateValue<Value>, ObservedStateValue<Value>) async -> Bool = {
            compare($0.value, $1.value)
        }
        let stateValues: MainActorSequence<Value> = values(on: keyPath)
        let values = stateValues.map { ObservedStateValue($0) }.removeDuplicates(by: compareValues)
        return MainActorSequence {
            var iterator = values.makeAsyncIterator()
            return { await iterator.next(isolation: MainActor.shared)?.value }
        }
    }

    func distinctValues<Value: Equatable>(on keyPath: KeyPath<State, Value>) -> MainActorSequence<Value> {
        distinctValues(on: keyPath, compare: { $0 == $1 })
    }

    @discardableResult
    func bind<OtherNsp: StoreNamespace, OtherValue>(
        to otherStore: OtherNsp.Store,
        on keyPath: KeyPath<OtherNsp.StoreState, OtherValue>,
        with action: @escaping (OtherValue) -> Action?,
        animation: Animation? = nil,
        compare: @escaping (OtherValue, OtherValue) -> Bool
    ) -> Task<Void, Never>? {
        // Subscribe before scheduling the effect so synchronous mutations cannot race registration.
        var iterator = otherStore.asyncValues(on: keyPath).makeAsyncIterator()
        return addEffect(.asyncActionSequence { send in
            var previous: OtherValue?
            while let value = await iterator.next() {
                guard !Task.isCancelled else { return }
                if let previous, compare(previous, value) { continue }
                previous = .some(value)
                if let action = action(value) { send(action, animation) }
            }
        })
    }
    
    @discardableResult
    func bind<OtherNsp: StoreNamespace, OtherValue: Equatable>(
        to otherStore: OtherNsp.Store,
        on keyPath: KeyPath<OtherNsp.StoreState, OtherValue>,
        with action: @escaping (OtherValue) -> Action?
    ) -> Task<Void, Never>? {
        bind(to: otherStore, on: keyPath, with: action, compare: { $0 == $1 })
    }
    
    @discardableResult
    func bindPublishedValue<OtherNsp: StoreNamespace>(
        of otherStore: OtherNsp.Store,
        with action: @escaping (OtherNsp.PublishedValue) -> Action,
        animation: Animation? = nil
    ) -> Task<Void, Never>? {
        var iterator = otherStore.throwingAsyncValues.makeAsyncIterator()
        return addEffect(.asyncActionSequence { send in
            do {
                while let value = try await iterator.next() {
                    guard !Task.isCancelled else { return }
                    send(action(value), animation)
                }
            }
            catch {
                guard !Task.isCancelled else { return }
                send(.cancel, animation)
            }
        })
    }
}

extension StateStore {
    public struct LogConfig {
        public var logState = false
        public var logActions = false
        public var logActionCallSite = false
#if DEBUG
        /// Opts this store into the shared app-run live-trace session configured by
        /// `LiveTraceConfig.shared`.
        ///
        /// Set to `nil` to disable live tracing, `.selfOnly` to trace just this store,
        /// or `.selfAndChildren` to also propagate tracing to child stores added later.
        /// If `LiveTraceConfig.shared.traceAllStores` is enabled, new stores default to
        /// `.selfAndChildren` until explicitly overridden.
        public var liveTraceEnabled: LiveTraceMode? = nil
#endif

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
}
