import Foundation
import FoundationEx
import Testing
@testable import ReducerArchitecture

private enum SessionGraphHarnessNsp: StoreNamespace {
    typealias PublishedValue = Void

    struct StoreEnvironment {}

    enum MutatingAction {
        case append(Int)
        case fanOut([Int])
    }

    enum EffectAction {
        case emitActions([Int])
        case emitSequence([Int])
        case startLongLivedSequence
        case none
    }

    struct StoreState: Equatable {
        var values: [Int] = []
    }
}

extension SessionGraphHarnessNsp {
    @MainActor
    static func store() -> Store {
        .init(.init(), env: .init())
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .append(let value):
            state.values.append(value)
            return .none

        case .fanOut(let values):
            return .actions(values.map { .mutating(.append($0)) })
        }
    }

    static func runEffect(_ env: StoreEnvironment, _ state: StoreState, _ action: EffectAction) -> Store.Effect {
        switch action {
        case .emitActions(let values):
            return .actions(values.map { .mutating(.append($0)) })

        case .emitSequence(let values):
            return .asyncActionSequence { send in
                for value in values {
                    send(.mutating(.append(value)))
                    await Task.yield()
                }
            }

        case .startLongLivedSequence:
            return .asyncActionSequence { send in
                while !Task.isCancelled {
                    send(.mutating(.append(1)))
                    try? await Task.sleep(for: .seconds(0.1))
                }
            }

        case .none:
            return .none
        }
    }
}

extension SessionTraceTests {
    @Suite @MainActor struct SessionGraphTests {}
}

extension SessionTraceTests.SessionGraphTests {
    @Test
    func sessionGraphCapturesInitialAndResultStateNodes() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        store.send(.mutating(.append(1)))

        let collection = try await collectionTask.value
        let graph = collection.sessionGraph

        let stateNodes = graph.nodes.compactMap { node -> SessionGraph.StateNode? in
            guard case .state(let value) = node else { return nil }
            return value
        }
        let mutatingAction = try #require(
            graph.nodes.compactMap { node -> SessionGraph.ActionNode? in
                guard case .action(let action) = node else { return nil }
                return action.kind == .mutating ? action : nil
            }.first
        )
        let stateInputEdges = graph.edges.compactMap { edge -> SessionGraph.StateInputEdge? in
            guard case .stateInput(let value) = edge else { return nil }
            return value
        }
        let stateResultEdges = graph.edges.compactMap { edge -> SessionGraph.StateResultEdge? in
            guard case .stateResult(let value) = edge else { return nil }
            return value
        }

        #expect(stateNodes.count == 2)
        #expect(stateInputEdges.count == 1)
        #expect(stateResultEdges.count == 1)

        let orderedStates = stateNodes.sorted(by: { $0.order < $1.order })
        #expect(orderedStates[0].state.first(where: { $0.property == "values" })?.value == "[]")
        #expect(orderedStates[1].state.first(where: { $0.property == "values" })?.value == "[1]")
        #expect(stateInputEdges[0].actionID == mutatingAction.id)
        #expect(stateResultEdges[0].actionID == mutatingAction.id)
    }

    @Test
    func sessionGraphCapturesActionDetailsInLiveTrace() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        store.send(.mutating(.append(1)))

        let collection = try await collectionTask.value
        let actionNodes = collection.sessionGraph.nodes.compactMap { node -> SessionGraph.ActionNode? in
            guard case .action(let value) = node else { return nil }
            return value
        }
        let firstAction = try #require(actionNodes.first)
        #expect(firstAction.stateBefore.first(where: { $0.property == "values" })?.value == "[]")
        #expect(firstAction.stateAfter?.first(where: { $0.property == "values" })?.value == "[1]")
        #expect(firstAction.outputEffect == ".none")
        #expect(firstAction.callSite != nil)
        #expect(firstAction.callSite?.file.contains("SessionGraphTests.swift") == true)
    }

    @Test
    func sessionGraphCapturesSyncFanOutWithBatchAndDiff() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        store.send(.mutating(.fanOut([1, 2])))

        let collection = try await collectionTask.value
        let graph = collection.sessionGraph

        let actionNodes = graph.nodes.compactMap { node -> SessionGraph.ActionNode? in
            guard case .action(let value) = node else { return nil }
            return value
        }
        let mutationNodes = graph.nodes.compactMap { node -> SessionGraph.MutationNode? in
            guard case .mutation(let value) = node else { return nil }
            return value
        }
        let batchNodes = graph.nodes.compactMap { node -> SessionGraph.BatchNode? in
            guard case .batch(let value) = node else { return nil }
            return value
        }
        let producedEdges = graph.edges.compactMap { edge -> SessionGraph.ProducedActionEdge? in
            guard case .producedAction(let value) = edge else { return nil }
            return value
        }
        let containsEdges = graph.edges.compactMap { edge -> SessionGraph.ContainsEdge? in
            guard case .contains(let value) = edge else { return nil }
            return value
        }

        #expect(actionNodes.count == 3)
        #expect(mutationNodes.count == 3)
        #expect(batchNodes.count == 1)

        let rootAction = try #require(actionNodes.first(where: { $0.source == .user }))
        let fanOutActions = actionNodes.filter { node in
            if case .action(let parentActionID) = node.source {
                return parentActionID == rootAction.id
            }
            return false
        }
        #expect(fanOutActions.count == 2)
        #expect(fanOutActions.allSatisfy { $0.callSite?.file.contains("SessionGraphTests.swift") == true })

        let orderedActionIds = actionNodes.sorted(by: { $0.order < $1.order }).map(\.id)
        #expect(orderedActionIds[0].rawValue.hasSuffix(".a1"))
        #expect(orderedActionIds[1].rawValue.hasSuffix(".a2"))
        #expect(orderedActionIds[2].rawValue.hasSuffix(".a3"))

        #expect(producedEdges.count == 1)
        #expect(containsEdges.count == 2)
        #expect(batchNodes.first?.kind == .syncFanOut)
        #expect(mutationNodes.filter {
            $0.propertyDiff.contains(where: { $0.property == "values" })
        }.count == 2)
    }

    @Test
    func sessionGraphCapturesEffectLifecycleBatchAndEmissions() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        let sequenceTask = store.send(.effect(.emitSequence([3, 4])))
        await sequenceTask?.value
        _ = store.send(.effect(.emitActions([5, 6])))

        let collection = try await collectionTask.value
        let graph = collection.sessionGraph

        let actionNodes = graph.nodes.compactMap { node -> SessionGraph.ActionNode? in
            guard case .action(let value) = node else { return nil }
            return value
        }
        let effectNodes = graph.nodes.compactMap { node -> SessionGraph.EffectNode? in
            guard case .effect(let value) = node else { return nil }
            return value
        }
        let batchNodes = graph.nodes.compactMap { node -> SessionGraph.BatchNode? in
            guard case .batch(let value) = node else { return nil }
            return value
        }
        let emittedEdges = graph.edges.compactMap { edge -> SessionGraph.EmittedActionEdge? in
            guard case .emittedAction(let value) = edge else { return nil }
            return value
        }
        let containsEdges = graph.edges.compactMap { edge -> SessionGraph.ContainsEdge? in
            guard case .contains(let value) = edge else { return nil }
            return value
        }

        let sequenceEffect = try #require(effectNodes.first(where: { $0.kind == .asyncActionSequence }))
        let batchEffect = try #require(effectNodes.first(where: { $0.kind == .actions }))
        let batchNode = try #require(batchNodes.first(where: { $0.kind == .effectActions }))

        #expect(sequenceEffect.emittedActionCount == 2)
        #expect(batchEffect.emittedActionCount == 2)

        let sequenceActions = actionNodes.filter { node in
            if case .effect(let effectID) = node.source {
                return effectID == sequenceEffect.id
            }
            return false
        }
        let batchActions = actionNodes.filter { node in
            if case .effect(let effectID) = node.source {
                return effectID == batchEffect.id
            }
            return false
        }
        #expect(sequenceActions.count == 2)
        #expect(batchActions.count == 2)

        #expect(
            emittedEdges.contains(where: {
                edge in
                edge.effectID == sequenceEffect.id &&
                sequenceActions.contains(where: { $0.id.rawValue == edge.nodeID })
            })
        )
        #expect(
            emittedEdges.contains(where: {
                $0.effectID == batchEffect.id && $0.nodeID == batchNode.id.rawValue
            })
        )
        #expect(containsEdges.filter { $0.batchID == batchNode.id }.count == 2)
    }

    @Test
    func sessionGraphMarksLongLivedEffectAsCancelled() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        let task = store.send(.effect(.startLongLivedSequence))
        try? await Task.sleep(for: .seconds(0.03))
        store.send(.cancel)
        await task?.value

        let collection = try await collectionTask.value
        let graph = collection.sessionGraph
        let effectNodes = graph.nodes.compactMap { node -> SessionGraph.EffectNode? in
            guard case .effect(let value) = node else { return nil }
            return value
        }

        let longLivedEffect = try #require(
            effectNodes.first(where: { $0.kind == .asyncActionSequence && $0.isLongLived })
        )
        #expect(longLivedEffect.lifecycle == .cancelled)
    }

    @Test
    func effectNoneDoesNotCreateEffectNode() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        store.send(.effect(.none))

        let collection = try await collectionTask.value
        let effectNodes = collection.sessionGraph.nodes.compactMap { node -> SessionGraph.EffectNode? in
            guard case .effect(let value) = node else { return nil }
            return value
        }
        #expect(effectNodes.isEmpty)
    }

    @Test
    func actionSourcesDoNotUseSystemSource() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        store.send(.mutating(.fanOut([1, 2])))
        _ = store.send(.effect(.emitActions([3, 4])))

        let collection = try await collectionTask.value
        let actionNodes = collection.sessionGraph.nodes.compactMap { node -> SessionGraph.ActionNode? in
            guard case .action(let value) = node else { return nil }
            return value
        }

        #expect(!actionNodes.isEmpty)
        #expect(actionNodes.allSatisfy {
            if case .system = $0.source { return false }
            return true
        })
    }

    @Test
    func liveTraceAccumulatorBuildsCollectionFromPatches() async throws {
        let store = SessionGraphHarnessNsp.store()
        let collectionTask = liveTraceCollectionTask(for: store)

        store.send(.mutating(.append(1)))

        let collection = try await collectionTask.value
        let actionNodes = collection.sessionGraph.nodes.compactMap { node -> SessionGraph.ActionNode? in
            guard case .action(let value) = node else { return nil }
            return value
        }
        let stateResultEdges = collection.sessionGraph.edges.compactMap { edge -> SessionGraph.StateResultEdge? in
            guard case .stateResult(let value) = edge else { return nil }
            return value
        }

        #expect(actionNodes.contains { $0.completedAt != nil })
        #expect(!stateResultEdges.isEmpty)
    }
}
