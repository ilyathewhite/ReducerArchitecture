//  SessionTracing.swift
//  Created by Ilya Belenkiy on 2/25/26.

import Foundation
import Combine
import FoundationEx
import os
#if canImport(SwiftUI)
import SwiftUI
#endif

@MainActor
private var sessionTraceStoreInstanceCounter = 0

@MainActor
private func nextSessionTraceStoreInstanceID(storeDefaultKey: String) -> SessionGraph.StoreInstanceID {
    sessionTraceStoreInstanceCounter += 1
    return .init(rawValue: "\(storeDefaultKey).s\(sessionTraceStoreInstanceCounter)")
}

final class SessionTraceLiveHandler: @unchecked Sendable {
    private let metadata: SessionTraceLiveSessionMetadata
    private let handler: @Sendable (SessionTraceLiveEnvelope) -> Void
    private var hasEnded = false

    init(
        metadata: SessionTraceLiveSessionMetadata,
        handler: @escaping @Sendable (SessionTraceLiveEnvelope) -> Void
    ) {
        self.metadata = metadata
        self.handler = handler
        handler(.hello(metadata))
    }

    func record(_ patch: SessionTraceLivePatch) {
        guard !hasEnded else { return }
        handler(
            .patch(
                sessionID: metadata.sessionID,
                patch: patch
            )
        )
    }

    func endSession() {
        guard !hasEnded else { return }
        hasEnded = true
        handler(.end(sessionID: metadata.sessionID))
    }
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
    struct SessionTraceSendContext {
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
    struct SessionTraceEffectContext {
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
    /// The runtime uses this for `.actions` and similar fan-out paths after it has created a
    /// batch node that should own the emitted actions.
    struct SessionTraceBatchParameters {
        /// The lineage shared by each action in the batch.
        ///
        /// `trace.containingBatchID` points at the batch node created just before dispatch, so
        /// every emitted action is attached to that batch instead of being linked directly to the
        /// source action/effect.
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
        logConfig.liveTrace != nil || logConfig.liveTraceHandler != nil
    }

    @inline(__always)
    /// Returns the active session graph recorder, creating one lazily when needed.
    var sessionGraphTraceRecorder: SessionGraphRecorder? {
        guard isSessionGraphTracingEnabled else {
            return nil
        }
        let recorder = sessionGraphRecorder ?? sessionTraceEnsureRecorder()
        sessionTraceAttachLiveOutputsIfNeeded(to: recorder)
        return recorder
    }

    func resolvedSessionTraceTitle() -> String {
        logConfig.liveTrace?.title ?? name
    }

    func sessionTraceMetadata(for recorder: SessionGraphRecorder) -> SessionTraceLiveSessionMetadata {
        if let sessionTraceLiveMetadata {
            return sessionTraceLiveMetadata
        }

        let metadata = SessionTraceLiveSessionMetadata(
            sessionID: recorder.storeInstanceID.rawValue,
            title: resolvedSessionTraceTitle(),
            storeName: name,
            hostName: ProcessInfo.processInfo.hostName,
            processName: ProcessInfo.processInfo.processName,
            startedAt: .now
        )
        sessionTraceLiveMetadata = metadata
        return metadata
    }

    func sessionTraceAttachLiveOutputsIfNeeded(to recorder: SessionGraphRecorder) {
        let metadata = sessionTraceMetadata(for: recorder)

        if let liveTraceConfig = logConfig.liveTrace {
            if sessionTraceLiveClient == nil {
                sessionTraceLiveClient = SessionTraceLiveClient(
                    sessionID: metadata.sessionID,
                    config: liveTraceConfig,
                    metadata: metadata,
                    logger: logConfig.logger
                )
            }
            recorder.setLiveClient(sessionTraceLiveClient)
        }
        else {
            recorder.setLiveClient(nil)
            sessionTraceLiveClient?.endSession()
            sessionTraceLiveClient = nil
        }

        if let liveTraceHandler = logConfig.liveTraceHandler {
            if sessionTraceLiveHandler == nil {
                sessionTraceLiveHandler = SessionTraceLiveHandler(
                    metadata: metadata,
                    handler: liveTraceHandler
                )
            }
            recorder.setLiveHandler(sessionTraceLiveHandler)
        }
        else {
            recorder.setLiveHandler(nil)
            sessionTraceLiveHandler?.endSession()
            sessionTraceLiveHandler = nil
        }
    }

    func sessionTraceSyncLiveOutputsIfNeeded() {
        guard isSessionGraphTracingEnabled else {
            sessionTraceClearLiveOutputsIfNeeded()
            return
        }
        if let recorder = sessionGraphRecorder {
            sessionTraceAttachLiveOutputsIfNeeded(to: recorder)
        }
    }

    func sessionTraceClearLiveOutputsIfNeeded() {
        guard sessionTraceLiveClient != nil ||
                sessionTraceLiveHandler != nil ||
                sessionTraceLiveMetadata != nil else {
            return
        }

        sessionGraphRecorder?.setLiveClient(nil)
        sessionGraphRecorder?.setLiveHandler(nil)
        sessionTraceLiveClient?.endSession()
        sessionTraceLiveClient = nil
        sessionTraceLiveHandler?.endSession()
        sessionTraceLiveHandler = nil
        sessionTraceLiveMetadata = nil
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
        trace: SessionTraceSendContext
    ) -> String? {
        guard let recorder = sessionGraphTraceRecorder else { return nil }
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
            sessionTraceAttachLiveOutputsIfNeeded(to: sessionGraphRecorder)
            return sessionGraphRecorder
        }
        let recorder = SessionGraphRecorder(
            storeInstanceID: nextSessionTraceStoreInstanceID(storeDefaultKey: Self.storeDefaultKey)
        )
        sessionGraphRecorder = recorder
        sessionTraceAttachLiveOutputsIfNeeded(to: recorder)
        return recorder
    }

    /// Builds tracing context for an action emitted by an effect.
    func sessionTraceContextForEffectAction(
        effectID: SessionGraph.EffectID?,
        animationGroupID: String?,
        containingBatchID: SessionGraph.BatchID?
    ) -> SessionTraceSendContext {
        if sessionGraphTraceRecorder != nil {
            assert(effectID != nil, "Missing effect id while tracing effect-origin action")
        }
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
        if sessionGraphTraceRecorder != nil {
            assert(actionID != nil, "Missing action id while tracing action-origin action")
        }
        let source: SessionGraph.ActionNode.Source = actionID.map { .action(actionID: $0) } ?? .user
        return .init(
            source: source,
            animationGroupID: animationGroupID,
            containingBatchID: containingBatchID
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
        let batchID: SessionGraph.BatchID?
        if dispatchingSyncEffect {
            batchID = beginSessionTraceBatchIfNeeded(
                kind: .syncFanOut,
                actionCount: actionCount,
                animationGroupID: trace.inheritedAnimationGroupID,
                producedByActionID: trace.startedByActionID,
                emittedByEffectID: nil
            )
        }
        else {
            batchID = beginSessionTraceBatchIfNeeded(
                kind: .effectActions,
                actionCount: actionCount,
                animationGroupID: animationGroupID,
                producedByActionID: nil,
                emittedByEffectID: effectID
            )
        }

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
            producedByActionID: nil,
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
        let animationGroupID = resolvedTraceAnimationGroupID(
            storeAction: storeAction,
            animation: animation,
            trace: trace
        )
        let recorder = sessionGraphTraceRecorder
        let stateBefore = recorder.map { _ in
            propertyCodeStrings(state)
        }
        let callSite: SessionGraph.ActionNode.CallSite? = {
            guard logConfig.logActionCallSite || isSessionGraphTracingEnabled else { return nil }
            guard let file, let line else { return nil }
            return .init(file: file, line: line)
        }()
        let shouldTraceAction: Bool = {
            if case .none = storeAction.action {
                return false
            }
            return true
        }()

        let actionID: SessionGraph.ActionID? = {
            guard shouldTraceAction,
                  let recorder,
                  let stateBefore else {
                return nil
            }
            return recorder.beginAction(
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
        }()

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
        guard let actionID = trace.actionID else { return }
        trace.recorder?.endAction(
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
        producedByActionID: SessionGraph.ActionID?,
        emittedByEffectID: SessionGraph.EffectID?
    ) -> SessionGraph.BatchID? {
        guard let recorder = sessionGraphTraceRecorder else { return nil }
        return recorder.beginBatch(
            kind: kind,
            actionCount: actionCount,
            nestedLevel: nestedLevel,
            animationGroupID: animationGroupID,
            producedByActionID: producedByActionID,
            emittedByEffectID: emittedByEffectID
        )
    }
}
