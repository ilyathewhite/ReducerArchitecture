//  SessionTracing.swift
//  Created by Ilya Belenkiy on 2/25/26.

import Foundation
import Combine
import FoundationEx
import os
#if canImport(SwiftUI)
import SwiftUI
#endif

private func normalizedSessionTraceValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

@MainActor
private final class SharedTraceSessionManager {
    static let shared = SharedTraceSessionManager()

    private var sharedSessionID: String?
    private var sharedTitle: String?
    private var autoStoreNameCountByType: [String: Int] = [:]
    private var sharedNetworkClient: LiveTraceClient?
    private var sharedNetworkHost: String?
    private var sharedNetworkPort: UInt16?
    private var sharedNetworkPatchBufferCapacity: Int?

    private init() {}

    func liveConfig() -> LiveTraceConfig {
        LiveTraceConfig.shared
    }

    func sessionID() -> String {
        if let sharedSessionID {
            return sharedSessionID
        }
        if let configuredSessionID = normalizedSessionTraceValue(liveConfig().sessionID) {
            sharedSessionID = configuredSessionID
            return configuredSessionID
        }

        let processName = ProcessInfo.processInfo.processName
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let generatedSessionID = "\(processName).session.\(UUID().uuidString.lowercased())"
        sharedSessionID = generatedSessionID
        return generatedSessionID
    }

    func sessionTitle() -> String {
        if let configuredTitle = normalizedSessionTraceValue(liveConfig().sessionTitle) {
            sharedTitle = configuredTitle
            return configuredTitle
        }
        if let sharedTitle {
            return sharedTitle
        }

        let defaultTitle = ProcessInfo.processInfo.processName
        sharedTitle = defaultTitle
        return defaultTitle
    }

    func nextAutoStoreName(for storeType: String) -> String {
        let nextCount = (autoStoreNameCountByType[storeType] ?? 0) + 1
        autoStoreNameCountByType[storeType] = nextCount
        return nextCount == 1 ? storeType : "\(storeType) \(nextCount)"
    }

    func reset() {
        stopNetworkClientIfNeeded()
        sharedSessionID = nil
        sharedTitle = nil
        autoStoreNameCountByType = [:]
    }

    func networkClient(logger: Logger) -> LiveTraceClient? {
        let config = liveConfig()
        guard config.networkEnabled else {
            stopNetworkClientIfNeeded()
            return nil
        }

        if let sharedNetworkClient,
           sharedNetworkHost == config.host,
           sharedNetworkPort == config.port,
           sharedNetworkPatchBufferCapacity == config.patchBufferCapacity {
            return sharedNetworkClient
        }

        let previousClient = sharedNetworkClient
        let nextClient = LiveTraceClient(
            sessionID: sessionID(),
            config: config,
            logger: logger
        )
        sharedNetworkClient = nextClient
        sharedNetworkHost = config.host
        sharedNetworkPort = config.port
        sharedNetworkPatchBufferCapacity = config.patchBufferCapacity
        Task {
            await previousClient?.stop()
        }
        return nextClient
    }

    func stopNetworkClientIfNeeded() {
        let previousClient = sharedNetworkClient
        sharedNetworkClient = nil
        sharedNetworkHost = nil
        sharedNetworkPort = nil
        sharedNetworkPatchBufferCapacity = nil
        Task {
            await previousClient?.stop()
        }
    }
}

@MainActor
private var sessionTraceStoreInstanceCounter = 0

@MainActor
private func nextSessionTraceStoreInstanceID(storeDefaultKey: String) -> SessionGraph.StoreInstanceID {
    sessionTraceStoreInstanceCounter += 1
    return .init(rawValue: "\(storeDefaultKey).s\(sessionTraceStoreInstanceCounter)")
}

@MainActor
func resetLiveTraceRuntimeForTests() {
    SharedTraceSessionManager.shared.reset()
    sessionTraceStoreInstanceCounter = 0
}

struct LiveTraceHandler: Sendable {
    private let metadata: LiveTraceStoreMetadata
    private let handler: @Sendable (LiveTraceEnvelope) -> Void

    init(
        metadata: LiveTraceStoreMetadata,
        handler: @escaping @Sendable (LiveTraceEnvelope) -> Void
    ) {
        self.metadata = metadata
        self.handler = handler
        handler(.hello(metadata))
    }

    func sendStoreMetadata(_ metadata: LiveTraceStoreMetadata) {
        handler(.hello(metadata))
    }

    func record(_ patch: LiveTracePatch) {
        handler(
            .patch(
                sessionID: metadata.sessionID,
                storeInstanceID: metadata.storeInstanceID,
                patch: patch
            )
        )
    }
}

@MainActor
private protocol LiveTraceConfigurableStore: BasicViewModel {
    func applyInheritedLiveTrace(
        mode: LiveTraceMode,
        parentStoreInstanceID: String,
        childKeyInParentStore: String
    )
}

// Session tracing support only. The store runtime calls into these helpers
// from StateStore.swift when tracing is enabled.
extension StateStore {
    /// Carries the tracing lineage for one `send` operation.
    ///
    /// `StateStore.swift` threads this object through every internal send so the
    /// recorder can answer three questions for the resulting action node:
    /// 1. Who caused this send?
    /// 2. Should it inherit an existing animation lineage?
    /// 3. Should it be attached to an already-open batch node?
    struct SessionTraceSendContext: Sendable {
        /// The causal source recorded on the action node.
        ///
        /// `.user` is used for top-level public `send` calls, `.system` is used for runtime
        /// sends that are not causally tied to another traced node, `.action` is used when a
        /// synchronous reducer emission should be attributed directly to the action that produced
        /// it, and `.effect` is used when an already-started effect emits a later action.
        let source: SessionGraph.ActionNode.Source
        /// The animation lineage to reuse for this send, if one is active.
        ///
        /// An animation group is not a SwiftUI transaction object; it is a tracing identifier
        /// used to mark all nodes that belong to one logical animated chain. The runtime creates
        /// the id lazily the first time it sees animation with no inherited group:
        /// - a public/internal `send` with a non-`nil` animation
        /// - a `.mutating(..., animated: true, ...)` action
        /// - an effect whose own payload carries animation
        ///
        /// Once created, the same id is propagated through descendant synchronous fan-out and
        /// effect emissions for as long as callers keep passing it forward. There is no explicit
        /// "end" event; the lineage simply stops when later sends/effects do not inherit it.
        let animationGroupID: String?
        /// The batch node this action should be inserted into, if one was created upstream.
        ///
        /// When present, the recorder emits a `.contains` edge from the batch to the action and
        /// intentionally skips the direct `.producedAction`/`.emittedAction` edge for the action
        /// itself, because the batch node becomes the single causal wrapper for the grouped send.
        let containingBatchID: SessionGraph.BatchID?

        /// Creates the tracing lineage for one send.
        ///
        /// - Parameters:
        ///   - source: The causal origin that should be written onto the action node.
        ///   - animationGroupID: An animation lineage to inherit, or `nil` to allow the runtime
        ///     to decide whether a new lineage should be created.
        ///   - containingBatchID: The active batch node that should own the emitted action, or
        ///     `nil` when the action should be linked directly to its source.
        init(
            source: SessionGraph.ActionNode.Source,
            animationGroupID: String?,
            containingBatchID: SessionGraph.BatchID?
        ) {
            self.source = source
            self.animationGroupID = animationGroupID
            self.containingBatchID = containingBatchID
        }

        /// Root tracing context for public user-driven sends.
        ///
        /// The resulting action is treated as entering the store from outside the runtime, with
        /// no inherited animation lineage and no batch membership.
        static var user: Self {
            .init(source: .user, animationGroupID: nil, containingBatchID: nil)
        }

        /// Root tracing context for runtime-generated sends that have no causal parent node.
        ///
        /// This is the fallback for internal store machinery when the send should not appear as
        /// user input and is not a descendant of an already-traced action or effect.
        static var system: Self {
            .init(source: .system, animationGroupID: nil, containingBatchID: nil)
        }
    }

    /// Describes the traced action context that an effect should inherit.
    ///
    /// `StateStore.swift` builds this right before handing an `Effect` to `addEffect`.
    /// It lets tracing preserve the parent action/effect lineage even when the effect later
    /// emits work on another task.
    struct SessionTraceEffectContext: Sendable {
        /// The traced action whose output produced this effect.
        ///
        /// When non-`nil`, the recorder can create a `.startedEffect` edge for real effect nodes,
        /// or a `.producedAction` edge when a synchronous reducer fan-out emits actions without
        /// materializing a separate effect node.
        let startedByActionID: SessionGraph.ActionID?
        /// The animation lineage inherited from the parent action.
        ///
        /// Synchronous reducer output always reuses this value. Asynchronous effects also start
        /// with this lineage and only create a fresh animation group when they introduce their
        /// own animation while no inherited lineage exists.
        let inheritedAnimationGroupID: String?

        /// Creates the inherited tracing context for an effect.
        ///
        /// - Parameters:
        ///   - startedByActionID: The traced action whose returned `Effect` is about to run.
        ///   - inheritedAnimationGroupID: The animation lineage already associated with that
        ///     action, if any.
        init(
            startedByActionID: SessionGraph.ActionID?,
            inheritedAnimationGroupID: String?
        ) {
            self.startedByActionID = startedByActionID
            self.inheritedAnimationGroupID = inheritedAnimationGroupID
        }
    }

    struct SessionTraceEffectDescriptor {
        let kind: SessionGraph.EffectNode.Kind
        let isAsynchronous: Bool
        let isLongLived: Bool
        let cancellationKey: String?
        let hasAnimation: Bool
    }

    /// Opaque tracing state for one in-flight action.
    ///
    /// `beginSessionTraceActionIfNeeded` returns this value before reducer/effect execution.
    /// Later helpers pass the same value back so they can close the action node, record mutation
    /// diffs against the original pre-action state, and propagate lineage into any returned effect.
    struct SessionTraceActionScope {
        /// The recorder that opened the action node.
        ///
        /// This stays optional so the same runtime code can execute when tracing is disabled,
        /// but when non-`nil` every follow-up helper must use this exact recorder instance to
        /// finish the action consistently.
        let recorder: SessionGraphRecorder?
        /// The id of the action node that was opened for the send.
        ///
        /// This is `nil` when tracing is disabled or when the runtime intentionally skips tracing
        /// the action, such as `.none`.
        let actionID: SessionGraph.ActionID?
        /// The final animation lineage resolved for the action.
        ///
        /// This is the inherited group if one already existed; otherwise it is a newly allocated
        /// group only when the action itself requested animation. Any effect returned from the
        /// action inherits this exact value.
        let animationGroupID: String?
        /// The store state captured before the action started running.
        ///
        /// Mutation tracing uses this snapshot later so state diffs and state-input edges are
        /// computed against the exact pre-action state even if nested work happens before closing
        /// the action.
        let stateBefore: [CodePropertyValuePair]?

        /// Creates the tracing handle for one in-flight action.
        ///
        /// - Parameters:
        ///   - recorder: The recorder that opened the action node, or `nil` when tracing is off.
        ///   - actionID: The action node id that later helpers should finish.
        ///   - animationGroupID: The resolved animation lineage for the action.
        ///   - stateBefore: The pre-action state snapshot used for later diffing.
        init(
            recorder: SessionGraphRecorder?,
            actionID: SessionGraph.ActionID?,
            animationGroupID: String?,
            stateBefore: [CodePropertyValuePair]?
        ) {
            self.recorder = recorder
            self.actionID = actionID
            self.animationGroupID = animationGroupID
            self.stateBefore = stateBefore
        }

        static var disabled: Self {
            .init(
                recorder: nil,
                actionID: nil,
                animationGroupID: nil,
                stateBefore: nil
            )
        }
    }

    /// Tracing payload for one action emitted from an effect.
    ///
    /// The runtime uses this wrapper when it needs to forward both lineage and call-site data to
    /// a downstream `send`.
    struct SessionTraceParameters {
        /// The lineage that should be written onto the emitted action node.
        ///
        /// For synchronous reducer fan-out this usually points back to the producing action,
        /// because no separate effect node is created. For later asynchronous emissions it usually
        /// points at the effect node that emitted the action.
        let trace: SessionTraceSendContext
        /// The file that should be recorded as the action's call site, if any.
        ///
        /// Synchronous reducer fan-out preserves the reducer call site because the emission
        /// happens on the same stack frame. Asynchronous emissions usually clear this value so the
        /// trace does not misleadingly attribute later work to the original reducer location.
        let file: String?
        /// The line that should be recorded as the action's call site, if any.
        ///
        /// This follows the same rules as `file`.
        let line: Int?

        /// Creates the tracing payload for one effect-emitted action.
        ///
        /// - Parameters:
        ///   - trace: The lineage the emitted action should inherit.
        ///   - file: The call-site file to attach, when the emission should preserve one.
        ///   - line: The call-site line to attach, when the emission should preserve one.
        init(
            trace: SessionTraceSendContext,
            file: String?,
            line: Int?
        ) {
            self.trace = trace
            self.file = file
            self.line = line
        }
    }

    /// Tracing payload shared by every action emitted inside one traced batch.
    ///
    /// The runtime uses this for `.actions` and similar fan-out paths when it decides to create
    /// a batch node that should own the emitted actions.
    struct SessionTraceBatchParameters {
        /// The lineage shared by each action in the batch.
        ///
        /// When `trace.containingBatchID` is non-`nil`, emitted actions are attached to that
        /// batch instead of being linked directly to the source action/effect.
        let trace: SessionTraceSendContext
        /// The file that batched emitted actions should use as their call site, if any.
        ///
        /// As with `SessionTraceParameters`, synchronous reducer fan-out preserves the reducer
        /// call site, while asynchronous fan-out generally leaves this empty.
        let file: String?
        /// The line that batched emitted actions should use as their call site, if any.
        ///
        /// This follows the same rules as `file`.
        let line: Int?

        /// Creates the tracing payload for a batch of emitted actions.
        ///
        /// - Parameters:
        ///   - trace: The shared lineage, including the batch id that owns the actions.
        ///   - file: The call-site file to propagate to batched actions when appropriate.
        ///   - line: The call-site line to propagate to batched actions when appropriate.
        init(
            trace: SessionTraceSendContext,
            file: String?,
            line: Int?
        ) {
            self.trace = trace
            self.file = file
            self.line = line
        }
    }

    @inline(__always)
    /// Returns `true` when this store should trace session graph events.
    var isSessionGraphTracingEnabled: Bool {
        isSessionGraphTracingActive
    }

    @inline(__always)
    /// Returns the active session graph recorder, creating one lazily when needed.
    var sessionGraphTraceRecorder: SessionGraphRecorder? {
        guard isSessionGraphTracingEnabled else {
            return nil
        }
        return sessionGraphRecorder ?? sessionTraceEnsureRecorder()
    }

    @inline(__always)
    func shouldRecordSessionTraceAction(_ action: Action) -> Bool {
        if !isSessionGraphTracingEnabled {
            return false
        }
        else if case .none = action  {
            return false
        }
        return true
    }

    func resolvedTraceSessionTitle() -> String {
        SharedTraceSessionManager.shared.sessionTitle()
    }

    func isDefaultLiveTraceStoreName(_ value: String?) -> Bool {
        guard let normalizedValue = normalizedSessionTraceValue(value) else { return true }
        let storeTypeName = Self.storeDefaultKey
        let shortStoreTypeName = storeTypeName.split(separator: ".").last.map(String.init) ?? storeTypeName
        return normalizedValue == storeTypeName || normalizedValue == shortStoreTypeName
    }

    func resolvedLiveTraceStoreName() -> String {
        if let configuredName = normalizedSessionTraceValue(name),
           !isDefaultLiveTraceStoreName(configuredName) {
            return configuredName
        }
        if let existingName = normalizedSessionTraceValue(liveTraceMetadata?.storeName) {
            return existingName
        }

        let generatedName = SharedTraceSessionManager.shared.nextAutoStoreName(
            for: Self.storeDefaultKey
        )
        name = generatedName
        return generatedName
    }

    func resolvedLiveTraceMetadata(for recorder: SessionGraphRecorder) -> LiveTraceStoreMetadata {
        let metadata = LiveTraceStoreMetadata(
            sessionID: SharedTraceSessionManager.shared.sessionID(),
            storeInstanceID: recorder.storeInstanceID.rawValue,
            title: resolvedTraceSessionTitle(),
            storeName: resolvedLiveTraceStoreName(),
            parentStoreInstanceID: liveTraceParentStoreInstanceID,
            childKeyInParentStore: liveTraceChildKeyInParentStore,
            hostName: ProcessInfo.processInfo.hostName,
            processName: ProcessInfo.processInfo.processName,
            startedAt: liveTraceMetadata?.startedAt ?? .now,
            endedAt: nil
        )
        liveTraceMetadata = metadata
        return metadata
    }

    func attachLiveTraceOutputsIfNeeded(to recorder: SessionGraphRecorder) {
        let previousMetadata = liveTraceMetadata
        let metadata = resolvedLiveTraceMetadata(for: recorder)
        let liveTraceConfig = SharedTraceSessionManager.shared.liveConfig()

        if logConfig.liveTraceEnabled != nil, liveTraceConfig.networkEnabled {
            recorder.setLiveClient(
                SharedTraceSessionManager.shared.networkClient(logger: logConfig.logger),
                metadata: metadata
            )
        }
        else {
            recorder.setLiveClient(nil, metadata: nil)
            if !liveTraceConfig.networkEnabled {
                SharedTraceSessionManager.shared.stopNetworkClientIfNeeded()
            }
        }

        if logConfig.liveTraceEnabled != nil, let envelopeHandler = liveTraceConfig.envelopeHandler {
            if liveTraceHandler == nil {
                liveTraceHandler = LiveTraceHandler(
                    metadata: metadata,
                    handler: envelopeHandler
                )
            }
            else if previousMetadata != metadata {
                liveTraceHandler?.sendStoreMetadata(metadata)
            }
            recorder.setLiveHandler(liveTraceHandler)
        }
        else {
            recorder.setLiveHandler(nil)
            liveTraceHandler = nil
        }
    }

    func clearLiveTraceOutputsIfNeeded() {
        guard liveTraceHandler != nil ||
                liveTraceMetadata != nil else {
            return
        }

        sessionGraphRecorder?.setLiveClient(nil, metadata: nil)
        sessionGraphRecorder?.setLiveHandler(nil)
        liveTraceHandler = nil
        liveTraceMetadata = nil
        if !SharedTraceSessionManager.shared.liveConfig().networkEnabled {
            SharedTraceSessionManager.shared.stopNetworkClientIfNeeded()
        }
    }

    func handleLogConfigDidChange(previousConfig: LogConfig) {
        let hadLiveTraceEnabled = previousConfig.liveTraceEnabled != nil
        let hasLiveTraceEnabled = logConfig.liveTraceEnabled != nil
        isSessionGraphTracingActive = hasLiveTraceEnabled && SharedTraceSessionManager.shared.liveConfig().hasOutputs

        guard hadLiveTraceEnabled || hasLiveTraceEnabled || liveTraceMetadata != nil || liveTraceHandler != nil else {
            return
        }

        if isSessionGraphTracingActive {
            let recorder = sessionTraceEnsureRecorder()
            attachLiveTraceOutputsIfNeeded(to: recorder)
        }
        else {
            clearLiveTraceOutputsIfNeeded()
        }
    }

    nonisolated static func notifyLiveTraceStoreEndedOnDeinit(
        metadata: LiveTraceStoreMetadata?,
        handler: LiveTraceHandler?,
        logger: Logger
    ) {
        guard let metadata else { return }
        guard !metadata.isEnded else { return }

        let endedMetadata = metadata.ended()
        handler?.sendStoreMetadata(endedMetadata)

        Task { @MainActor in
            guard SharedTraceSessionManager.shared.liveConfig().networkEnabled else { return }
            guard let liveClient = SharedTraceSessionManager.shared.networkClient(logger: logger) else {
                return
            }
            await liveClient.updateStoreMetadata(endedMetadata)
        }
    }

    static func sessionTraceEffectDescriptor(for effect: Effect) -> SessionTraceEffectDescriptor {
        switch effect {
        case let .action(_, animation):
            return .init(
                kind: .action,
                isAsynchronous: false,
                isLongLived: false,
                cancellationKey: nil,
                hasAnimation: animation != nil
            )
        case let .actions(_, animation):
            return .init(
                kind: .actions,
                isAsynchronous: false,
                isLongLived: false,
                cancellationKey: nil,
                hasAnimation: animation != nil
            )
        case let .asyncAction(animation, _):
            return .init(
                kind: .asyncAction,
                isAsynchronous: true,
                isLongLived: false,
                cancellationKey: nil,
                hasAnimation: animation != nil
            )
        case let .asyncActionLatest(key, animation, _):
            return .init(
                kind: .asyncActionLatest,
                isAsynchronous: true,
                isLongLived: false,
                cancellationKey: key,
                hasAnimation: animation != nil
            )
        case let .asyncActions(animation, _):
            return .init(
                kind: .asyncActions,
                isAsynchronous: true,
                isLongLived: false,
                cancellationKey: nil,
                hasAnimation: animation != nil
            )
        case .asyncActionSequence:
            return .init(
                kind: .asyncActionSequence,
                isAsynchronous: true,
                isLongLived: true,
                cancellationKey: nil,
                hasAnimation: false
            )
        case let .asyncActionSequenceLatest(key, _):
            return .init(
                kind: .asyncActionSequenceLatest,
                isAsynchronous: true,
                isLongLived: true,
                cancellationKey: key,
                hasAnimation: false
            )
        case let .publisher(_, animation):
            return .init(
                kind: .publisher,
                isAsynchronous: true,
                isLongLived: true,
                cancellationKey: nil,
                hasAnimation: animation != nil
            )
        case .none:
            return .init(
                kind: .none,
                isAsynchronous: false,
                isLongLived: false,
                cancellationKey: nil,
                hasAnimation: false
            )
        }
    }

    func tracedActionKind(_ action: Action) -> SessionGraph.ActionNode.Kind {
        switch action {
        case .mutating:
            return .mutating
        case .effect:
            return .effect
        case .publish:
            return .publish
        case .cancel:
            return .cancel
        case .none:
            return .none
        }
    }

    func tracedActionCase(_ action: Action) -> String {
        switch action {
        case let .mutating(mutatingAction, _, _):
            return caseName(mutatingAction)
        case let .effect(effectAction):
            return caseName(effectAction)
        case .publish, .cancel:
            return caseName(action)
        case .none:
            return "none"
        }
    }

    func resolvedTraceAnimationGroupID(
        storeAction: StoreAction,
        animation: Animation?,
        trace: SessionTraceSendContext,
        recorder: SessionGraphRecorder
    ) -> String? {
        if let animationGroupID = trace.animationGroupID {
            return animationGroupID
        }
        if animation != nil {
            return recorder.makeAnimationGroupID()
        }
        if case .mutating(_, let animated, _) = storeAction.action, animated {
            return recorder.makeAnimationGroupID()
        }
        return nil
    }

    func sessionTraceEnsureRecorder() -> SessionGraphRecorder {
        if let sessionGraphRecorder {
            return sessionGraphRecorder
        }
        let recorder = SessionGraphRecorder(
            storeInstanceID: nextSessionTraceStoreInstanceID(storeDefaultKey: Self.storeDefaultKey)
        )
        sessionGraphRecorder = recorder
        attachLiveTraceOutputsIfNeeded(to: recorder)
        return recorder
    }

    /// Builds tracing context for an action emitted by an effect.
    func sessionTraceContextForEffectAction(
        effectID: SessionGraph.EffectID?,
        animationGroupID: String?,
        containingBatchID: SessionGraph.BatchID?
    ) -> SessionTraceSendContext {
        let source: SessionGraph.ActionNode.Source = effectID.map { .effect(effectID: $0) } ?? .user
        return .init(
            source: source,
            animationGroupID: animationGroupID,
            containingBatchID: containingBatchID
        )
    }

    /// Builds tracing context for an action emitted synchronously by another action.
    func sessionTraceContextForProducedAction(
        actionID: SessionGraph.ActionID?,
        animationGroupID: String?,
        containingBatchID: SessionGraph.BatchID?
    ) -> SessionTraceSendContext {
        let source: SessionGraph.ActionNode.Source = actionID.map { .action(actionID: $0) } ?? .user
        return .init(
            source: source,
            animationGroupID: animationGroupID,
            containingBatchID: containingBatchID
        )
    }

    func configureLiveTraceForAddedChildIfNeeded<VM: BasicViewModel>(
        _ child: VM,
        key: String
    ) {
        guard isSessionGraphTracingEnabled else { return }
        guard logConfig.liveTraceEnabled == .selfAndChildren else { return }
        guard let childStore = child as? any LiveTraceConfigurableStore else { return }

        let parentStoreInstanceID = sessionTraceEnsureRecorder().storeInstanceID.rawValue
        childStore.applyInheritedLiveTrace(
            mode: .selfAndChildren,
            parentStoreInstanceID: parentStoreInstanceID,
            childKeyInParentStore: key
        )
    }

    /// Resolves tracing context and forwarded call-site information for one effect-emitted action.
    func sessionTraceParametersForEffectAction(
        dispatchingSyncEffect: Bool,
        trace: SessionTraceEffectContext,
        effectID: SessionGraph.EffectID?,
        animationGroupID: String?,
        file: String?,
        line: Int?,
        containingBatchID: SessionGraph.BatchID?
    ) -> SessionTraceParameters {
        if dispatchingSyncEffect {
            return .init(
                trace: sessionTraceContextForProducedAction(
                    actionID: trace.startedByActionID,
                    animationGroupID: trace.inheritedAnimationGroupID,
                    containingBatchID: containingBatchID
                ),
                file: file,
                line: line
            )
        }
        else {
            return .init(
                trace: sessionTraceContextForEffectAction(
                    effectID: effectID,
                    animationGroupID: animationGroupID,
                    containingBatchID: containingBatchID
                ),
                file: nil,
                line: nil
            )
        }
    }

    /// Resolves tracing context for an effect that emits multiple actions as one batch.
    func sessionTraceBatchParametersForEffectActions(
        dispatchingSyncEffect: Bool,
        trace: SessionTraceEffectContext,
        effectID: SessionGraph.EffectID?,
        animationGroupID: String?,
        actionCount: Int,
        file: String?,
        line: Int?
    ) -> SessionTraceBatchParameters {
        let batchID: SessionGraph.BatchID? = dispatchingSyncEffect
            ? nil
            : beginSessionTraceBatchIfNeeded(
                kind: .effectActions,
                actionCount: actionCount,
                animationGroupID: animationGroupID,
                emittedByEffectID: effectID
            )

        return .init(
            trace: sessionTraceParametersForEffectAction(
                dispatchingSyncEffect: dispatchingSyncEffect,
                trace: trace,
                effectID: effectID,
                animationGroupID: animationGroupID,
                file: file,
                line: line,
                containingBatchID: batchID
            ).trace,
            file: dispatchingSyncEffect ? file : nil,
            line: dispatchingSyncEffect ? line : nil
        )
    }

    /// Resolves tracing context for async effect emissions that are fanned out concurrently.
    func sessionTraceParametersForAsyncEffectActions(
        effectID: SessionGraph.EffectID?,
        animationGroupID: String?,
        actionCount: Int
    ) -> SessionTraceSendContext {
        let batchID = beginSessionTraceBatchIfNeeded(
            kind: .effectAsyncActions,
            actionCount: actionCount,
            animationGroupID: animationGroupID,
            emittedByEffectID: effectID
        )

        return sessionTraceContextForEffectAction(
            effectID: effectID,
            animationGroupID: animationGroupID,
            containingBatchID: batchID
        )
    }

    /// Starts tracing an incoming action and captures its pre-action state snapshot.
    func beginSessionTraceActionIfNeeded(
        storeAction: StoreAction,
        animation: Animation?,
        trace: SessionTraceSendContext,
        file: String?,
        line: Int?
    ) -> SessionTraceActionScope {
        guard shouldRecordSessionTraceAction(storeAction.action) else {
            return .disabled
        }

        let recorder = sessionTraceEnsureRecorder()
        let animationGroupID = resolvedTraceAnimationGroupID(
            storeAction: storeAction,
            animation: animation,
            trace: trace,
            recorder: recorder
        )
        let stateBefore = propertyCodeStrings(state)
        let callSite = file.flatMap { file in
            line.map { SessionGraph.ActionNode.CallSite(file: file, line: $0) }
        }
        let actionID = recorder.beginAction(
            receivedAt: .now,
            action: codeString(storeAction.action),
            actionCase: tracedActionCase(storeAction.action),
            kind: tracedActionKind(storeAction.action),
            source: trace.source,
            nestedLevel: nestedLevel,
            animationGroupID: animationGroupID,
            stateBefore: stateBefore,
            callSite: callSite,
            containingBatchID: trace.containingBatchID
        )

        return .init(
            recorder: recorder,
            actionID: actionID,
            animationGroupID: animationGroupID,
            stateBefore: stateBefore
        )
    }

    /// Finishes a previously started action trace with the resulting state and output effect.
    func finishSessionTraceActionIfNeeded(
        _ trace: SessionTraceActionScope,
        outputEffect: Effect?
    ) {
        guard let recorder = trace.recorder,
              let actionID = trace.actionID else { return }
        recorder.endAction(
            actionID,
            completedAt: .now,
            stateAfter: propertyCodeStrings(state),
            outputEffect: codeString(outputEffect)
        )
    }

    /// Records the mutation diff and state transition for a traced mutating action.
    func recordSessionTraceMutationIfNeeded(_ trace: SessionTraceActionScope) {
        guard let recorder = trace.recorder,
              let actionID = trace.actionID,
              let stateBefore = trace.stateBefore else { return }

        let stateAfter = propertyCodeStrings(state)
        _ = recorder.recordMutation(
            appliedAt: .now,
            actionID: actionID,
            nestedLevel: nestedLevel,
            before: stateBefore,
            after: stateAfter
        )
        recorder.recordStateTransition(
            appliedAt: .now,
            actionID: actionID,
            stateBefore: stateBefore,
            stateAfter: stateAfter
        )
    }

    /// Cancels every traced effect still marked active for the store.
    func cancelAllActiveSessionTraceEffectsIfNeeded(_ trace: SessionTraceActionScope) {
        trace.recorder?.cancelAllActiveEffects()
    }

    /// Starts tracing an effect and returns the effect id plus inherited animation grouping.
    func beginSessionTraceEffectIfNeeded(
        _ effect: Effect,
        trace: SessionTraceEffectContext
    ) -> (effectID: SessionGraph.EffectID?, animationGroupID: String?) {
        var animationGroupID = trace.inheritedAnimationGroupID
        let descriptor = Self.sessionTraceEffectDescriptor(for: effect)
        guard descriptor.kind != .none else {
            return (effectID: nil, animationGroupID: animationGroupID)
        }
        guard let recorder = sessionGraphTraceRecorder else {
            return (effectID: nil, animationGroupID: animationGroupID)
        }

        if animationGroupID == nil, descriptor.hasAnimation {
            animationGroupID = recorder.makeAnimationGroupID()
        }
        let effectID = recorder.beginEffect(
            kind: descriptor.kind,
            isAsynchronous: descriptor.isAsynchronous,
            isLongLived: descriptor.isLongLived,
            cancellationKey: descriptor.cancellationKey,
            startedByActionID: trace.startedByActionID,
            nestedLevel: nestedLevel,
            animationGroupID: animationGroupID
        )
        return (effectID: effectID, animationGroupID: animationGroupID)
    }

    /// Starts tracing an effect unless it is being dispatched synchronously from reducer output.
    func beginSessionTraceEffectIfNeeded(
        _ effect: Effect,
        trace: SessionTraceEffectContext,
        dispatchingSyncEffect: Bool
    ) -> (effectID: SessionGraph.EffectID?, animationGroupID: String?) {
        if dispatchingSyncEffect {
            return (effectID: nil, animationGroupID: trace.inheritedAnimationGroupID)
        }
        return beginSessionTraceEffectIfNeeded(effect, trace: trace)
    }

    /// Starts tracing a batch node for grouped action emissions when tracing is enabled.
    func beginSessionTraceBatchIfNeeded(
        kind: SessionGraph.BatchNode.Kind,
        actionCount: Int,
        animationGroupID: String?,
        emittedByEffectID: SessionGraph.EffectID?
    ) -> SessionGraph.BatchID? {
        guard let recorder = sessionGraphTraceRecorder else { return nil }
        return recorder.beginBatch(
            kind: kind,
            actionCount: actionCount,
            nestedLevel: nestedLevel,
            animationGroupID: animationGroupID,
            emittedByEffectID: emittedByEffectID
        )
    }
}

@MainActor
extension StateStore: LiveTraceConfigurableStore {
    fileprivate func applyInheritedLiveTrace(
        mode: LiveTraceMode,
        parentStoreInstanceID: String,
        childKeyInParentStore: String
    ) {
        liveTraceParentStoreInstanceID = parentStoreInstanceID
        liveTraceChildKeyInParentStore = childKeyInParentStore
        logConfig.liveTraceEnabled = mode
    }
}
