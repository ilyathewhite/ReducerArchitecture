//
//  ReducerArchitectureSessionGraph.swift
//
//  Created by Ilya Belenkiy on 2/25/26.
//

import Foundation
import FoundationEx
import Tagged

/// Immutable snapshot of one traced store session.
///
/// A session graph is the serialized view of what the runtime recorder captured while a single
/// `StateStore` instance was active. Nodes describe observed entities such as actions, mutations,
/// effects, batches, and state snapshots. Edges describe why those nodes exist and how control
/// and data moved between them.
public struct SessionGraph: Codable, Equatable {
    public enum StoreInstanceIDTag {}
    /// Identifies one traced store instance within a session graph.
    public typealias StoreInstanceID = Tagged<StoreInstanceIDTag, String>

    public enum StateIDTag {}
    /// Identifies a traced state node within a session graph.
    public typealias StateID = Tagged<StateIDTag, String>

    public enum ActionIDTag {}
    /// Identifies a traced action node within a session graph.
    public typealias ActionID = Tagged<ActionIDTag, String>

    public enum MutationIDTag {}
    /// Identifies a traced mutation node within a session graph.
    public typealias MutationID = Tagged<MutationIDTag, String>

    public enum EffectIDTag {}
    /// Identifies a traced effect node within a session graph.
    public typealias EffectID = Tagged<EffectIDTag, String>

    public enum BatchIDTag {}
    /// Identifies a traced batch node within a session graph.
    public typealias BatchID = Tagged<BatchIDTag, String>

    /// The schema version written by newly saved traces.
    public static let currentSchemaVersion = 2

    /// Version of the serialized graph schema used by this snapshot.
    ///
    /// Readers can use this to branch when the on-disk meaning of nodes or edges changes.
    public let schemaVersion: Int
    /// The store instance that produced the trace.
    ///
    /// Every node and animation-group id in the graph is prefixed from this value, which makes
    /// it possible to correlate ids while keeping them unique across traces.
    public let storeInstanceID: StoreInstanceID
    /// All recorded nodes for the session.
    ///
    /// Consumers should treat `order` as the canonical event sequence rather than array position,
    /// because graphs are sorted before being returned/saved.
    public let nodes: [Node]
    /// All recorded causal/structural edges for the session.
    ///
    /// Like `nodes`, these are conceptually ordered by their `order` field, not by storage index.
    public let edges: [Edge]

    public init(
        schemaVersion: Int = SessionGraph.currentSchemaVersion,
        storeInstanceID: StoreInstanceID,
        nodes: [Node],
        edges: [Edge]
    ) {
        self.schemaVersion = schemaVersion
        self.storeInstanceID = storeInstanceID
        self.nodes = nodes
        self.edges = edges
    }

    /// Type-erased wrapper around every node kind that can appear in a trace.
    public enum Node: Codable, Equatable {
        case state(StateNode)
        case action(ActionNode)
        case mutation(MutationNode)
        case effect(EffectNode)
        case batch(BatchNode)

        /// String form of the wrapped node id.
        ///
        /// This is primarily for heterogeneous consumers such as graph viewers that need to key
        /// mixed node collections in one dictionary.
        public var id: String {
            switch self {
            case .state(let node):
                return node.id.rawValue
            case .action(let node):
                return node.id.rawValue
            case .mutation(let node):
                return node.id.rawValue
            case .effect(let node):
                return node.id.rawValue
            case .batch(let node):
                return node.id.rawValue
            }
        }

        /// Global event order of the wrapped node.
        ///
        /// Orders are monotonic across all node kinds inside one trace.
        public var order: Int {
            switch self {
            case .state(let node):
                return node.order
            case .action(let node):
                return node.order
            case .mutation(let node):
                return node.order
            case .effect(let node):
                return node.order
            case .batch(let node):
                return node.order
            }
        }
    }

    /// Snapshot of the store state at a particular moment.
    ///
    /// State nodes anchor mutating actions: a mutating action consumes one state via
    /// `StateInputEdge` and produces the next state via `StateResultEdge`.
    public struct StateNode: Codable, Equatable, Identifiable {
        /// Unique id of this state snapshot within the session.
        public let id: StateID
        /// Global order in which the snapshot was recorded.
        ///
        /// This is the ordering key used to place the node in the overall trace timeline.
        public let order: Int
        /// Wall-clock time at which the snapshot was captured.
        public let capturedAt: Date
        /// Stringified property/value pairs for the full store state.
        ///
        /// The recorder stores a full snapshot instead of only diffs so traces remain inspectable
        /// even when intermediate nodes are collapsed or a viewer wants to show exact before/after
        /// state for any action.
        public let state: [CodePropertyValuePair]
    }

    /// One action observed entering the store runtime.
    ///
    /// This includes user sends, reducer-produced sends, effect emissions, publish/cancel
    /// actions, and even `.none` when the runtime chooses to represent it.
    public struct ActionNode: Codable, Equatable, Identifiable {
        public enum Kind: String, Codable {
            /// A synchronous state-changing reducer action.
            case mutating
            /// An action that asks `runEffect` to produce an `Effect`.
            case effect
            /// An action that publishes a value to a parent flow.
            case publish
            /// An action that cancels the store and active tasks.
            case cancel
            /// Sentinel/no-op action value.
            case none
        }

        /// Describes the immediate causal source recorded for an action node.
        public enum Source: Codable, Equatable {
            /// The action entered the store through the public user-facing `send` API.
            case user
            /// The action was emitted by an effect node that was already started.
            case effect(effectID: EffectID)
            /// The action was produced synchronously by another action, usually reducer fan-out.
            case action(actionID: ActionID)
            /// The action came from store runtime machinery rather than user input.
            case system
        }

        /// Source file/line captured for the send that created this action.
        public struct CallSite: Codable, Equatable {
            /// File passed through the runtime for this send.
            public let file: String
            /// Line passed through the runtime for this send.
            public let line: Int
        }

        /// Unique id of this action within the session.
        public let id: ActionID
        /// Global order in which the action was first observed by the runtime.
        public let order: Int
        /// Wall-clock time at which the store received the action.
        public let receivedAt: Date
        /// Stringified action payload as seen by the runtime.
        public let action: String
        /// Case name extracted from the action for grouping/searching in tooling.
        public let actionCase: String
        /// Coarse runtime category of the action.
        public let kind: Kind
        /// Immediate causal parent recorded for the action.
        ///
        /// This distinguishes user input from reducer-produced sends and later effect emissions,
        /// which is what allows viewers to choose better predecessor edges than simple time order.
        public let source: Source
        /// Store nesting depth at which the action ran.
        ///
        /// This increments when reducer/effect execution re-enters the store before the outer
        /// action finishes, and helps viewers identify nested control flow.
        public let nestedLevel: Int
        /// Animation lineage carried by this action, if any.
        ///
        /// The value groups this action with any ancestor/descendant nodes that participate in the
        /// same logical animated chain. It is allocated lazily and only exists when the runtime
        /// observed animation on the action/effect path.
        public let animationGroupID: String?
        /// Full pre-action state snapshot.
        ///
        /// This is captured before reducer/effect work begins so later mutation/state-transition
        /// nodes can be interpreted against the exact input state of the action.
        public let stateBefore: [CodePropertyValuePair]
        /// File/line metadata for the originating send, if the runtime propagated it.
        public let callSite: CallSite?
        /// Wall-clock time at which action handling finished.
        ///
        /// This remains `nil` while the action node is still open in the recorder.
        public var completedAt: Date?
        /// Full post-action state snapshot, when the action completed.
        ///
        /// For mutating actions this reflects state after reducer execution. For other action kinds
        /// it records the state observed when the runtime finished handling the action.
        public var stateAfter: [CodePropertyValuePair]?
        /// Stringified `Effect` value returned by handling the action.
        ///
        /// This captures what the action scheduled next, even if the resulting effect nodes/actions
        /// execute later.
        public var outputEffect: String?
    }

    /// Record of the concrete state mutation work performed for a mutating action.
    ///
    /// Mutation nodes exist alongside action nodes so traces can separately show the action that
    /// requested a state change and the actual before/after diff that resulted.
    public struct MutationNode: Codable, Equatable, Identifiable {
        /// Per-property diff extracted from a mutation's before/after snapshots.
        public struct PropertyDiff: Codable, Equatable {
            /// Name of the state property whose stringified value changed.
            public let property: String
            /// Property value before the mutation, or `nil` if the property was absent.
            public let beforeValue: String?
            /// Property value after the mutation, or `nil` if the property was removed.
            public let afterValue: String?
        }

        /// Unique id of this mutation within the session.
        public let id: MutationID
        /// Global order in which the mutation node was recorded.
        public let order: Int
        /// Wall-clock time at which the mutation was applied.
        public let appliedAt: Date
        /// Action responsible for the mutation.
        public let actionID: ActionID
        /// Store nesting depth at which the mutation was recorded.
        public let nestedLevel: Int
        /// Full state snapshot immediately before the mutation.
        public let before: [CodePropertyValuePair]
        /// Full state snapshot immediately after the mutation.
        public let after: [CodePropertyValuePair]
        /// Changed properties derived from `before` and `after`.
        ///
        /// This is precomputed so consumers can render focused diffs without re-deriving them.
        public let propertyDiff: [PropertyDiff]
    }

    /// Record of one `Effect` instance started by the runtime.
    ///
    /// Effect nodes represent scheduled work rather than emitted actions themselves. Later edges
    /// such as `StartedEffectEdge` and `EmittedActionEdge` tie the effect to the action that
    /// created it and the actions/batches it emitted.
    public struct EffectNode: Codable, Equatable, Identifiable {
        public enum Kind: String, Codable {
            /// `.action`
            case action
            /// `.actions`
            case actions
            /// `.asyncAction`
            case asyncAction
            /// `.asyncActionLatest`
            case asyncActionLatest
            /// `.asyncActions`
            case asyncActions
            /// `.asyncActionSequence`
            case asyncActionSequence
            /// `.asyncActionSequenceLatest`
            case asyncActionSequenceLatest
            /// `.publisher`
            case publisher
            /// `.none`
            case none
        }

        /// Lifecycle state of a started effect node.
        public enum Lifecycle: String, Codable {
            /// The effect has started and has not yet been finished/cancelled.
            case started
            /// The effect completed normally.
            case finished
            /// The effect was cancelled or superseded before normal completion.
            case cancelled
        }

        /// Unique id of this effect within the session.
        public let id: EffectID
        /// Global order in which the effect node was started.
        public let order: Int
        /// Runtime effect variant that created the node.
        public let kind: Kind
        /// Whether the effect executes outside the immediate reducer call stack.
        ///
        /// This helps viewers decide whether continuation edges should be rendered as asynchronous.
        public let isAsynchronous: Bool
        /// Whether the effect can remain active across multiple emissions over time.
        ///
        /// Long-lived effects include sequences and publishers that may keep producing actions
        /// until completion or cancellation.
        public let isLongLived: Bool
        /// Cancellation key used for latest-only replacement semantics, if any.
        ///
        /// When a later effect starts with the same key, the recorder marks the previous effect as
        /// cancelled before registering the new one.
        public let cancellationKey: String?
        /// Action that started this effect, if the runtime had one in scope.
        ///
        /// Synchronous reducer fan-out may skip creating an effect node entirely, so the absence
        /// of this value does not always mean the work had no logical parent.
        public let startedByActionID: ActionID?
        /// Store nesting depth at which the effect was started.
        public let nestedLevel: Int
        /// Animation lineage inherited or created for the effect.
        ///
        /// Descendant actions emitted by the effect may inherit this same id.
        public let animationGroupID: String?
        /// Number of emitted actions attributed to the effect so far.
        ///
        /// This is updated incrementally as emitted actions are recorded, even when they are later
        /// wrapped in batch nodes.
        public var emittedActionCount: Int
        /// Current lifecycle state of the effect.
        public var lifecycle: Lifecycle
        /// Global order at which the effect finished or was cancelled.
        ///
        /// This remains `nil` while `lifecycle == .started`.
        public var endOrder: Int?
    }

    /// Synthetic grouping node for one fan-out of multiple emitted actions.
    ///
    /// Batch nodes collapse "many children from one source" into one causal wrapper so viewers can
    /// show a single predecessor edge from the source to the batch, then ordered containment edges
    /// from the batch to each emitted action.
    public struct BatchNode: Codable, Equatable, Identifiable {
        public enum Kind: String, Codable {
            /// Multiple actions returned synchronously from reducer output.
            case syncFanOut
            /// Multiple actions emitted synchronously by an effect.
            case effectActions
            /// Multiple actions emitted concurrently/asynchronously by an effect.
            case effectAsyncActions
        }

        /// Unique id of this batch within the session.
        public let id: BatchID
        /// Global order in which the batch node was created.
        public let order: Int
        /// Runtime fan-out path that created the batch.
        public let kind: Kind
        /// Number of actions the runtime expected to insert into the batch.
        ///
        /// This is the planned fan-out count, which helps consumers reason about partial or full
        /// emission even if they do not walk every contained edge.
        public let actionCount: Int
        /// Store nesting depth at which the batch was created.
        public let nestedLevel: Int
        /// Animation lineage shared by the batched emitted actions, if any.
        public let animationGroupID: String?
    }

    /// Type-erased wrapper around every edge kind that can appear in a trace.
    public enum Edge: Codable, Equatable {
        case stateInput(StateInputEdge)
        case stateResult(StateResultEdge)
        case applied(AppliedEdge)
        case startedEffect(StartedEffectEdge)
        case emittedAction(EmittedActionEdge)
        case producedAction(ProducedActionEdge)
        case contains(ContainsEdge)
        case nested(NestedEdge)

        /// Global order in which the edge was recorded.
        ///
        /// Edges interleave with node orders because both are generated from one monotonic counter.
        public var order: Int {
            switch self {
            case .stateInput(let edge):
                return edge.order
            case .stateResult(let edge):
                return edge.order
            case .applied(let edge):
                return edge.order
            case .startedEffect(let edge):
                return edge.order
            case .emittedAction(let edge):
                return edge.order
            case .producedAction(let edge):
                return edge.order
            case .contains(let edge):
                return edge.order
            case .nested(let edge):
                return edge.order
            }
        }
    }

    /// Connects a mutating action to the state snapshot it consumed.
    public struct StateInputEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// State snapshot that was current when the mutating action started.
        public let stateID: StateID
        /// Mutating action that consumed the state snapshot.
        public let actionID: ActionID
    }

    /// Connects a mutating action to the state snapshot it produced.
    public struct StateResultEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// Mutating action that produced the result state.
        public let actionID: ActionID
        /// Resulting state snapshot after the mutation completed.
        public let stateID: StateID
    }

    /// Connects an action node to its mutation node.
    public struct AppliedEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// Action that caused the mutation.
        public let actionID: ActionID
        /// Mutation node describing the actual state diff.
        public let mutationID: MutationID
    }

    /// Connects an action node to an effect node it started.
    public struct StartedEffectEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// Action that returned the effect.
        public let actionID: ActionID
        /// Effect node that was started from that action.
        public let effectID: EffectID
    }

    /// Connects an effect to one node it emitted directly.
    ///
    /// `nodeID` may point to either an `ActionNode` or a `BatchNode`. When a batch wrapper exists,
    /// the edge targets the batch rather than each individual action.
    public struct EmittedActionEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// Effect responsible for the emission.
        public let effectID: EffectID
        /// Emitted action node id, or batch node id when the emission was grouped.
        public let nodeID: String
        /// 1-based emission sequence for nodes emitted by this effect.
        ///
        /// This preserves effect-local ordering independently of unrelated events interleaving in
        /// the global trace timeline.
        public let emissionIndex: Int
    }

    /// Connects an action to another node it produced synchronously.
    ///
    /// Like `EmittedActionEdge`, `nodeID` may point to either an `ActionNode` or a `BatchNode`.
    public struct ProducedActionEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// Action responsible for producing the node.
        public let actionID: ActionID
        /// Produced action node id, or batch node id when fan-out was grouped.
        public let nodeID: String
        /// 1-based production sequence for nodes produced by this action.
        public let productionIndex: Int
    }

    /// Connects a batch node to one node contained in that batch.
    public struct ContainsEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// Batch that owns the emitted node.
        public let batchID: BatchID
        /// Child node contained in the batch.
        public let nodeID: String
        /// 1-based position of the child within the batch.
        ///
        /// This preserves the batch-local order that viewers should use when drawing grouped
        /// emissions.
        public let itemIndex: Int
    }

    /// Connects an already-open action node to a descendant node created during re-entrant work.
    ///
    /// This is structural rather than causal: it records stack nesting when the store receives
    /// new work before the parent action finishes.
    public struct NestedEdge: Codable, Equatable {
        /// Global order in which the edge was recorded.
        public let order: Int
        /// Parent action or batch node that was active when the child node was created.
        public let parentNodeID: String
        /// Descendant node created while the parent was still open.
        public let childNodeID: String
    }
}

@MainActor
/// Builds the in-memory session graph for one store instance while tracing is active.
///
/// The recorder is the mutable bridge between runtime events and the immutable `SessionGraph`
/// snapshot that eventually gets saved. It owns monotonic order/id counters, tracks currently
/// open actions so nested edges can be emitted correctly, and remembers the latest effect for each
/// cancellation key so replacement semantics can be recorded.
final class SessionGraphRecorder {
    /// The store-instance id used as the prefix for every generated node and animation-group id.
    let storeInstanceID: SessionGraph.StoreInstanceID

    private var nodes: [SessionGraph.Node] = []
    private var edges: [SessionGraph.Edge] = []

    private var nextOrder = 0
    private var nextState = 0
    private var nextAction = 0
    private var nextMutation = 0
    private var nextEffect = 0
    private var nextBatch = 0
    private var nextAnimationGroup = 0

    private var actionStack: [SessionGraph.ActionID] = []
    private var actionNodeIndexByID: [SessionGraph.ActionID: Int] = [:]
    private var effectNodeIndexByID: [SessionGraph.EffectID: Int] = [:]
    private var containsIndexByBatchID: [SessionGraph.BatchID: Int] = [:]
    private var productionIndexByActionID: [SessionGraph.ActionID: Int] = [:]
    private var emissionEdgeIndexByEffectID: [SessionGraph.EffectID: Int] = [:]
    private var latestEffectByKey: [String: SessionGraph.EffectID] = [:]
    private var latestStateNodeID: SessionGraph.StateID?

    /// Creates a recorder for one store instance.
    ///
    /// The supplied `storeInstanceID` becomes the stable prefix for all ids emitted into the
    /// current graph snapshot.
    init(storeInstanceID: SessionGraph.StoreInstanceID) {
        self.storeInstanceID = storeInstanceID
    }

    /// Returns `true` after the recorder has captured at least one node.
    ///
    /// Persistence helpers use this to avoid saving empty trace files.
    var hasEvents: Bool {
        !nodes.isEmpty
    }

    /// Allocates a new animation-lineage identifier.
    ///
    /// The tracing layer asks for one only when an animated action/effect does not already
    /// inherit a lineage from its parent. Descendant sends reuse the returned id until the runtime
    /// stops propagating it.
    func makeAnimationGroupID() -> String {
        nextAnimationGroup += 1
        return "\(storeInstanceID).g\(nextAnimationGroup)"
    }

    func beginAction(
        receivedAt: Date,
        action: String,
        actionCase: String,
        kind: SessionGraph.ActionNode.Kind,
        source: SessionGraph.ActionNode.Source,
        nestedLevel: Int,
        animationGroupID: String?,
        stateBefore: [CodePropertyValuePair],
        callSite: SessionGraph.ActionNode.CallSite?,
        containingBatchID: SessionGraph.BatchID?
    ) -> SessionGraph.ActionID {
        ensureInitialStateNodeIfNeeded(
            capturedAt: receivedAt,
            state: stateBefore
        )

        let actionID = makeActionID()
        let node = SessionGraph.ActionNode(
            id: actionID,
            order: makeOrder(),
            receivedAt: receivedAt,
            action: action,
            actionCase: actionCase,
            kind: kind,
            source: source,
            nestedLevel: nestedLevel,
            animationGroupID: animationGroupID,
            stateBefore: stateBefore,
            callSite: callSite,
            completedAt: nil,
            stateAfter: nil,
            outputEffect: nil
        )
        nodes.append(.action(node))
        actionNodeIndexByID[actionID] = nodes.endIndex - 1

        if let parentActionID = actionStack.last {
            edges.append(
                .nested(
                    .init(
                        order: makeOrder(),
                        parentNodeID: parentActionID.rawValue,
                        childNodeID: actionID.rawValue
                    )
                )
            )
        }

        if let containingBatchID {
            edges.append(
                .contains(
                    .init(
                        order: makeOrder(),
                        batchID: containingBatchID,
                        nodeID: actionID.rawValue,
                        itemIndex: nextContainsIndex(for: containingBatchID)
                    )
                )
            )
        }

        switch source {
        case .effect(let effectID):
            incrementEmittedActionCount(for: effectID)
            if containingBatchID == nil {
                edges.append(
                    .emittedAction(
                        .init(
                            order: makeOrder(),
                            effectID: effectID,
                            nodeID: actionID.rawValue,
                            emissionIndex: nextEmissionEdgeIndex(for: effectID)
                        )
                    )
                )
            }

        case .action(let parentActionID):
            if containingBatchID == nil {
                edges.append(
                    .producedAction(
                        .init(
                            order: makeOrder(),
                            actionID: parentActionID,
                            nodeID: actionID.rawValue,
                            productionIndex: nextProductionIndex(for: parentActionID)
                        )
                    )
                )
            }

        case .user, .system:
            break
        }

        actionStack.append(actionID)
        return actionID
    }

    func endAction(
        _ actionID: SessionGraph.ActionID,
        completedAt: Date,
        stateAfter: [CodePropertyValuePair],
        outputEffect: String
    ) {
        if let nodeIndex = actionNodeIndexByID[actionID],
           case .action(var actionNode) = nodes[nodeIndex],
           actionNode.completedAt == nil {
            actionNode.completedAt = completedAt
            actionNode.stateAfter = stateAfter
            actionNode.outputEffect = outputEffect
            nodes[nodeIndex] = .action(actionNode)
        }
        guard let stackIndex = actionStack.lastIndex(of: actionID) else {
            return
        }
        actionStack.remove(at: stackIndex)
    }

    func recordMutation(
        appliedAt: Date,
        actionID: SessionGraph.ActionID,
        nestedLevel: Int,
        before: [CodePropertyValuePair],
        after: [CodePropertyValuePair]
    ) -> SessionGraph.MutationID {
        let mutationID = makeMutationID()
        let node = SessionGraph.MutationNode(
            id: mutationID,
            order: makeOrder(),
            appliedAt: appliedAt,
            actionID: actionID,
            nestedLevel: nestedLevel,
            before: before,
            after: after,
            propertyDiff: Self.propertyDiff(before: before, after: after)
        )
        nodes.append(.mutation(node))
        edges.append(
            .applied(
                .init(
                    order: makeOrder(),
                    actionID: actionID,
                    mutationID: mutationID
                )
            )
        )
        return mutationID
    }

    func recordStateTransition(
        appliedAt: Date,
        actionID: SessionGraph.ActionID,
        stateBefore: [CodePropertyValuePair],
        stateAfter: [CodePropertyValuePair]
    ) {
        ensureInitialStateNodeIfNeeded(
            capturedAt: appliedAt,
            state: stateBefore
        )
        guard let inputStateID = latestStateNodeID else {
            return
        }

        edges.append(
            .stateInput(
                .init(
                    order: makeOrder(),
                    stateID: inputStateID,
                    actionID: actionID
                )
            )
        )

        let resultStateID = appendStateNode(
            capturedAt: appliedAt,
            state: stateAfter
        )
        edges.append(
            .stateResult(
                .init(
                    order: makeOrder(),
                    actionID: actionID,
                    stateID: resultStateID
                )
            )
        )
    }

    func beginEffect(
        kind: SessionGraph.EffectNode.Kind,
        isAsynchronous: Bool,
        isLongLived: Bool,
        cancellationKey: String?,
        startedByActionID: SessionGraph.ActionID?,
        nestedLevel: Int,
        animationGroupID: String?
    ) -> SessionGraph.EffectID {
        if let cancellationKey, let previousEffectID = latestEffectByKey[cancellationKey] {
            completeEffect(previousEffectID, cancelled: true)
        }

        let effectID = makeEffectID()
        let node = SessionGraph.EffectNode(
            id: effectID,
            order: makeOrder(),
            kind: kind,
            isAsynchronous: isAsynchronous,
            isLongLived: isLongLived,
            cancellationKey: cancellationKey,
            startedByActionID: startedByActionID,
            nestedLevel: nestedLevel,
            animationGroupID: animationGroupID,
            emittedActionCount: 0,
            lifecycle: .started,
            endOrder: nil
        )
        nodes.append(.effect(node))
        effectNodeIndexByID[effectID] = nodes.endIndex - 1

        if let startedByActionID {
            edges.append(
                .startedEffect(
                    .init(
                        order: makeOrder(),
                        actionID: startedByActionID,
                        effectID: effectID
                    )
                )
            )
        }

        if let cancellationKey {
            latestEffectByKey[cancellationKey] = effectID
        }

        return effectID
    }

    func beginBatch(
        kind: SessionGraph.BatchNode.Kind,
        actionCount: Int,
        nestedLevel: Int,
        animationGroupID: String?,
        producedByActionID: SessionGraph.ActionID?,
        emittedByEffectID: SessionGraph.EffectID?
    ) -> SessionGraph.BatchID {
        let batchID = makeBatchID()
        let node = SessionGraph.BatchNode(
            id: batchID,
            order: makeOrder(),
            kind: kind,
            actionCount: actionCount,
            nestedLevel: nestedLevel,
            animationGroupID: animationGroupID
        )
        nodes.append(.batch(node))

        if let parentActionID = actionStack.last {
            edges.append(
                .nested(
                    .init(
                        order: makeOrder(),
                        parentNodeID: parentActionID.rawValue,
                        childNodeID: batchID.rawValue
                    )
                )
            )
        }

        if let producedByActionID {
            edges.append(
                .producedAction(
                    .init(
                        order: makeOrder(),
                        actionID: producedByActionID,
                        nodeID: batchID.rawValue,
                        productionIndex: nextProductionIndex(for: producedByActionID)
                    )
                )
            )
        }

        if let emittedByEffectID {
            edges.append(
                .emittedAction(
                    .init(
                        order: makeOrder(),
                        effectID: emittedByEffectID,
                        nodeID: batchID.rawValue,
                        emissionIndex: nextEmissionEdgeIndex(for: emittedByEffectID)
                    )
                )
            )
        }

        return batchID
    }

    func completeEffect(_ effectID: SessionGraph.EffectID, cancelled: Bool) {
        guard let nodeIndex = effectNodeIndexByID[effectID] else {
            return
        }
        guard case .effect(var effectNode) = nodes[nodeIndex] else {
            return
        }
        guard effectNode.lifecycle == .started else {
            return
        }

        effectNode.lifecycle = cancelled ? .cancelled : .finished
        effectNode.endOrder = makeOrder()
        nodes[nodeIndex] = .effect(effectNode)

        if let key = effectNode.cancellationKey, latestEffectByKey[key] == effectID {
            latestEffectByKey.removeValue(forKey: key)
        }
    }

    func cancelAllActiveEffects() {
        let activeEffectIDs = nodes.compactMap { node -> SessionGraph.EffectID? in
            guard case .effect(let effect) = node, effect.lifecycle == .started else { return nil }
            return effect.id
        }
        for effectID in activeEffectIDs {
            completeEffect(effectID, cancelled: true)
        }
    }

    /// Returns an immutable snapshot of the currently recorded graph.
    ///
    /// Nodes and edges are sorted before returning so persistence and tests see stable ordering.
    /// Returns `nil` when the recorder has not captured any events yet.
    func graph() -> SessionGraph? {
        guard hasEvents else { return nil }
        return SessionGraph(
            storeInstanceID: storeInstanceID,
            nodes: nodes.sorted(by: Self.nodeSort),
            edges: edges.sorted(by: Self.edgeSort)
        )
    }

    /// Clears the current trace segment while preserving the recorder object.
    ///
    /// Manual save uses this after persisting so the same store can continue tracing into a fresh
    /// graph without allocating a new recorder instance.
    func reset() {
        nodes = []
        edges = []
        actionStack = []
        actionNodeIndexByID = [:]
        effectNodeIndexByID = [:]
        containsIndexByBatchID = [:]
        productionIndexByActionID = [:]
        emissionEdgeIndexByEffectID = [:]
        latestEffectByKey = [:]
        nextOrder = 0
        nextState = 0
        nextAction = 0
        nextMutation = 0
        nextEffect = 0
        nextBatch = 0
        nextAnimationGroup = 0
        latestStateNodeID = nil
    }

    private func incrementEmittedActionCount(for effectID: SessionGraph.EffectID) {
        guard let nodeIndex = effectNodeIndexByID[effectID] else {
            return
        }
        guard case .effect(var effectNode) = nodes[nodeIndex] else {
            return
        }
        effectNode.emittedActionCount += 1
        nodes[nodeIndex] = .effect(effectNode)
    }

    private func nextContainsIndex(for batchID: SessionGraph.BatchID) -> Int {
        let nextValue = (containsIndexByBatchID[batchID] ?? 0) + 1
        containsIndexByBatchID[batchID] = nextValue
        return nextValue
    }

    private func nextProductionIndex(for actionID: SessionGraph.ActionID) -> Int {
        let nextValue = (productionIndexByActionID[actionID] ?? 0) + 1
        productionIndexByActionID[actionID] = nextValue
        return nextValue
    }

    private func nextEmissionEdgeIndex(for effectID: SessionGraph.EffectID) -> Int {
        let nextValue = (emissionEdgeIndexByEffectID[effectID] ?? 0) + 1
        emissionEdgeIndexByEffectID[effectID] = nextValue
        return nextValue
    }

    private func makeOrder() -> Int {
        nextOrder += 1
        return nextOrder
    }

    private func makeActionID() -> SessionGraph.ActionID {
        nextAction += 1
        return .init(rawValue: "\(storeInstanceID).a\(nextAction)")
    }

    private func makeStateID() -> SessionGraph.StateID {
        nextState += 1
        return .init(rawValue: "\(storeInstanceID).st\(nextState)")
    }

    private func makeMutationID() -> SessionGraph.MutationID {
        nextMutation += 1
        return .init(rawValue: "\(storeInstanceID).m\(nextMutation)")
    }

    private func makeEffectID() -> SessionGraph.EffectID {
        nextEffect += 1
        return .init(rawValue: "\(storeInstanceID).e\(nextEffect)")
    }

    private func makeBatchID() -> SessionGraph.BatchID {
        nextBatch += 1
        return .init(rawValue: "\(storeInstanceID).b\(nextBatch)")
    }

    private static func propertyDiff(
        before: [CodePropertyValuePair],
        after: [CodePropertyValuePair]
    ) -> [SessionGraph.MutationNode.PropertyDiff] {
        let beforeValues = Dictionary(
            uniqueKeysWithValues: before.map { ($0.property, $0.value) }
        )
        let afterValues = Dictionary(
            uniqueKeysWithValues: after.map { ($0.property, $0.value) }
        )
        let changedProperties = Set(beforeValues.keys)
            .union(afterValues.keys)
            .sorted()
            .filter { beforeValues[$0] != afterValues[$0] }
        return changedProperties.map { property in
            .init(
                property: property,
                beforeValue: beforeValues[property],
                afterValue: afterValues[property]
            )
        }
    }

    private static func nodeSort(lhs: SessionGraph.Node, rhs: SessionGraph.Node) -> Bool {
        if lhs.order == rhs.order {
            return lhs.id < rhs.id
        }
        return lhs.order < rhs.order
    }

    private static func edgeSort(lhs: SessionGraph.Edge, rhs: SessionGraph.Edge) -> Bool {
        lhs.order < rhs.order
    }

    private func ensureInitialStateNodeIfNeeded(
        capturedAt: Date,
        state: [CodePropertyValuePair]
    ) {
        guard latestStateNodeID == nil else { return }
        _ = appendStateNode(
            capturedAt: capturedAt,
            state: state
        )
    }

    @discardableResult
    private func appendStateNode(
        capturedAt: Date,
        state: [CodePropertyValuePair]
    ) -> SessionGraph.StateID {
        let stateID = makeStateID()
        let node = SessionGraph.StateNode(
            id: stateID,
            order: makeOrder(),
            capturedAt: capturedAt,
            state: state
        )
        nodes.append(.state(node))
        latestStateNodeID = stateID
        return stateID
    }
}
