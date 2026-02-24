import Combine
import Foundation
import Testing
@testable import ReducerArchitecture

private enum NestedTaskGapNsp: StoreNamespace {
    typealias PublishedValue = String

    struct StoreEnvironment {
        var publisher: AnyPublisher<Store.Action, Never>
    }

    enum MutatingAction {
        case append(Int)
    }

    enum EffectAction {
        case spawnAsync(Int)
        case emitAsync(Int)
        case emitAsyncLatest(value: Int, delay: TimeInterval)
        case emitAsyncActions([Int])
        case emitAsyncSequence([Int])
        case subscribeToPublisher
    }

    struct StoreState: Equatable {
        var values: [Int] = []
    }
}

extension NestedTaskGapNsp {
    @MainActor
    static func store(
        publisher: AnyPublisher<Store.Action, Never> = Empty<Store.Action, Never>(completeImmediately: false).eraseToAnyPublisher()
    ) -> Store {
        .init(.init(), env: .init(publisher: publisher))
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .append(let value):
            state.values.append(value)
            return .none
        }
    }

    static func runEffect(_ env: StoreEnvironment, _ state: StoreState, _ action: EffectAction) -> Store.Effect {
        switch action {
        case .spawnAsync(let value):
            return .asyncAction {
                .mutating(.append(value))
            }

        case .emitAsync(let value):
            return .asyncAction {
                .effect(.spawnAsync(value))
            }

        case .emitAsyncLatest(let value, let delay):
            return .asyncActionLatest(key: "latest") {
                try? await Task.sleep(for: .seconds(delay))
                return .effect(.spawnAsync(value))
            }

        case .emitAsyncActions(let values):
            return .asyncActions {
                values.map { .effect(.spawnAsync($0)) }
            }

        case .emitAsyncSequence(let values):
            return .asyncActionSequence { send in
                for value in values {
                    send(.effect(.spawnAsync(value)))
                    await Task.yield()
                }
            }

        case .subscribeToPublisher:
            return .publisher(env.publisher)
        }
    }
}

private enum DefaultReducerGapNsp: StoreNamespace {
    typealias PublishedValue = Void
    struct StoreEnvironment {}
    typealias MutatingAction = Void
    typealias EffectAction = Never

    struct StoreState: Equatable {
        var value = 0
    }
}

private enum SyncActionGapNsp: StoreNamespace {
    typealias PublishedValue = Void
    typealias StoreEnvironment = Never
    typealias EffectAction = Never

    enum MutatingAction {
        case triggerFollowUp
        case append(Int)
    }

    struct StoreState: Equatable {
        var values: [Int] = []
    }
}

extension SyncActionGapNsp {
    @MainActor
    static func store() -> Store {
        .init(.init(), env: nil)
    }

    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        case .triggerFollowUp:
            return .action(.mutating(.append(4)))
        case .append(let value):
            state.values.append(value)
            return .none
        }
    }
}

extension StateStoreTests {
    @Suite @MainActor struct StateStoreCoverageGapTests {}
}

extension StateStoreTests.StateStoreCoverageGapTests {
    // MARK: - Namespace Defaults

    // Reduce on default Void/Never namespace.
    // Expect sync effect is none.
    @Test
    func defaultVoidReducerReturnsNoneSyncEffect() {
        // Set up state.
        var state = DefaultReducerGapNsp.StoreState(value: 0)

        // Trigger default reducer.
        let effect = DefaultReducerGapNsp.reduce(&state, ())

        // Expect none sync effect.
        let isNoneEffect: Bool
        if case .none = effect {
            isNoneEffect = true
        }
        else {
            isNoneEffect = false
        }
        #expect(isNoneEffect)
    }

    // Check lifecycle log default exclusion.
    // Expect placeholder excluded and custom name allowed.
    @Test
    func storeLifecycleDefaultExcludeFiltersNavigationPlaceholder() {
        // Set up default lifecycle logger.
        let log = StoreLifecycleLog()

        // Trigger exclude predicate.
        let excludesPlaceholder = log.exclude("NavigationEnvPlaceholder")
        let excludesCustomName = log.exclude("CustomStore")

        // Expect only placeholder is excluded.
        #expect(excludesPlaceholder)
        #expect(!excludesCustomName)
    }

    // MARK: - Store Helpers

    // Check static action helpers and publish flag.
    // Expect noAction is none and publish flag is correct.
    @Test
    func actionHelpersExposePublishAndNoAction() {
        // Set up actions.
        let noAction = NestedTaskGapNsp.Store.Action.noAction
        let publishAction = NestedTaskGapNsp.Store.Action.publish("result")
        let effectAction = NestedTaskGapNsp.Store.Action.effect(.spawnAsync(1))

        // Trigger no-action pattern match.
        let isNoActionNone: Bool
        switch noAction {
        case .none:
            isNoActionNone = true
        default:
            isNoActionNone = false
        }

        // Expect helper behavior.
        #expect(isNoActionNone)
        #expect(publishAction.isPublish)
        #expect(!effectAction.isPublish)
    }

    // Wrap user and code actions.
    // Expect isFromUser reflects wrapper case.
    @Test
    func storeActionTracksWhetherActionIsUserInitiated() {
        // Set up wrapped actions.
        let user = NestedTaskGapNsp.Store.StoreAction.user(.none)
        let code = NestedTaskGapNsp.Store.StoreAction.code(.none)

        // Expect wrapper source flags.
        #expect(user.isFromUser)
        #expect(!code.isFromUser)
    }

    // Build snapshots from user and code actions.
    // Expect isFromUser only for user input snapshots.
    @Test
    func snapshotInputAndWrapperExposeUserOrigin() {
        // Set up snapshot payloads.
        let userInput = NestedTaskGapNsp.Store.Snapshot.Input(
            date: .now,
            action: .user(.none),
            state: .init(),
            nestedLevel: 0
        )
        let codeInput = NestedTaskGapNsp.Store.Snapshot.Input(
            date: .now,
            action: .code(.none),
            state: .init(),
            nestedLevel: 0
        )
        let stateChange = NestedTaskGapNsp.Store.Snapshot.StateChange(
            date: .now,
            state: .init(values: [1]),
            nestedLevel: 0
        )

        // Trigger wrapper checks.
        let userSnapshot = NestedTaskGapNsp.Store.Snapshot.input(userInput)
        let codeSnapshot = NestedTaskGapNsp.Store.Snapshot.input(codeInput)
        let stateChangeSnapshot = NestedTaskGapNsp.Store.Snapshot.stateChange(stateChange)

        // Expect user origin only for user inputs.
        #expect(userInput.isFromUser)
        #expect(!codeInput.isFromUser)
        #expect(userSnapshot.isFromUser)
        #expect(!codeSnapshot.isFromUser)
        #expect(!stateChangeSnapshot.isFromUser)
    }

    // Query AnyStore children by key.
    // Expect only AnyStore children are returned.
    @Test
    func anyStoreAnyChildReturnsOnlyAnyStoreChildren() {
        // Set up parent with store and non-store children.
        let parent = NestedTaskGapNsp.store()
        let storeChild = NestedTaskGapNsp.store()
        let basicChild = BaseViewModel<Void>()
        parent.children["store"] = storeChild
        parent.children["basic"] = basicChild
        let erasedParent: any AnyStore = parent

        // Trigger child lookups.
        let anyStoreChild = erasedParent.anyChild(key: "store")
        let nonStoreChild = erasedParent.anyChild(key: "basic")

        // Expect only store child survives casting.
        #expect(anyStoreChild === storeChild)
        #expect(nonStoreChild == nil)
    }

    // MARK: - Effect Execution

    // Return SyncEffect.action from reducer.
    // Expect follow-up mutating action runs.
    @Test
    func reducerSyncEffectActionRunsFollowUpAction() {
        // Set up store.
        let store = SyncActionGapNsp.store()

        // Trigger reducer follow-up action.
        store.send(.mutating(.triggerFollowUp))

        // Expect follow-up mutation applied.
        #expect(store.state.values == [4])
    }

    // Add explicit none effect.
    // Expect no task is created.
    @Test
    func addEffectNoneReturnsNil() {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger none effect.
        let task = store.addEffect(.none)

        // Expect no task.
        #expect(task == nil)
    }

    // Send .none action.
    // Expect state remains unchanged and no task.
    @Test
    func sendNoneReturnsNilAndKeepsState() {
        // Set up store with baseline state.
        let store = NestedTaskGapNsp.store()
        store.send(.mutating(.append(1)))

        // Trigger none action.
        let task = store.send(.none)

        // Expect unchanged values and no task.
        #expect(task == nil)
        #expect(store.state.values == [1])
    }

    // Cancel store and send cancel again.
    // Expect repeated cancel is ignored.
    @Test
    func sendCancelAfterCancellationReturnsNil() {
        // Set up and cancel store.
        let store = NestedTaskGapNsp.store()
        store.cancel()

        // Trigger repeated cancel.
        let repeatedCancel = store.send(.cancel)

        // Expect no work and cancelled state.
        #expect(repeatedCancel == nil)
        #expect(store.isCancelled)
    }

    // Send action with explicit animation parameter.
    // Expect animated apply path still mutates state.
    @Test
    func animatedSendPathMutatesState() {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger send with top-level animation.
        _ = store.send(.mutating(.append(1)), .default)

        // Expect mutation applied.
        #expect(store.state.values == [1])
    }

    // Send mutating action marked animated.
    // Expect animated reducer branch mutates state.
    @Test
    func animatedMutatingActionPathMutatesState() {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger animated mutating action.
        _ = store.send(.mutating(.append(2), animated: true, .default))

        // Expect state update.
        #expect(store.state.values == [2])
    }

    // Send animated mutating action without explicit animation.
    // Expect default animation branch mutates state.
    @Test
    func animatedMutatingActionWithoutExplicitAnimationUsesDefault() {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger animated action with nil animation payload.
        _ = store.send(.mutating(.append(3), animated: true))

        // Expect state update.
        #expect(store.state.values == [3])
    }

    // Add .actions with nested async effects.
    // Expect returned task waits for all values.
    @Test
    func addEffectActionsWaitsForNestedAsyncTasks() async {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger grouped nested effects.
        let task = store.addEffect(
            .actions([
                .effect(.spawnAsync(1)),
                .effect(.spawnAsync(2))
            ])
        )
        await task?.value

        // Expect all nested values.
        #expect(task != nil)
        #expect(store.state.values.sorted() == [1, 2])
    }

    // Emit async action that emits nested async effect.
    // Expect task completes after nested mutation.
    @Test
    func asyncActionAwaitsNestedTaskBeforeCompletion() async {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger nested async action.
        let task = store.send(.effect(.emitAsync(3)))
        await task?.value

        // Expect nested mutation applied.
        #expect(store.state.values == [3])
    }

    // Emit two async-latest nested effects.
    // Expect only latest nested value is applied.
    @Test
    func asyncActionLatestAwaitsNestedTaskBeforeCompletion() async {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger competing async-latest operations.
        let first = store.send(.effect(.emitAsyncLatest(value: 1, delay: 0.15)))
        let second = store.send(.effect(.emitAsyncLatest(value: 2, delay: 0.02)))
        await first?.value
        await second?.value

        // Expect latest nested result only.
        #expect(store.state.values == [2])
    }

    // Emit async-actions nested effects.
    // Expect all nested actions complete before return.
    @Test
    func asyncActionsAwaitNestedTasksBeforeCompletion() async {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger async action batch.
        let task = store.send(.effect(.emitAsyncActions([4, 5, 6])))
        await task?.value

        // Expect all nested values.
        #expect(store.state.values.sorted() == [4, 5, 6])
    }

    // Emit async-sequence nested effects.
    // Expect setup completes before nested async drain.
    @Test
    func asyncActionSequenceForwardsNestedValuesAfterSetupCompletes() async {
        // Set up store.
        let store = NestedTaskGapNsp.store()

        // Trigger sequence effect.
        let task = store.send(.effect(.emitAsyncSequence([7, 8, 9])))
        await task?.value
        try? await Task.sleep(for: .seconds(0.05))

        // Expect all sequence values.
        #expect(store.state.values.sorted() == [7, 8, 9])
    }

    // Subscribe to delayed publisher output.
    // Expect delayed published value is forwarded.
    @Test
    func publisherEffectForwardsDelayedPublishedValue() async {
        // Set up delayed single-value publisher and store.
        let publisher = Just(NestedTaskGapNsp.Store.Action.effect(.spawnAsync(10)))
            .delay(for: .seconds(0.01), scheduler: DispatchQueue.main)
            .eraseToAnyPublisher()
        let store = NestedTaskGapNsp.store(publisher: publisher)

        // Trigger effect and await delayed publish.
        await store.send(.effect(.subscribeToPublisher))?.value
        try? await Task.sleep(for: .seconds(0.1))

        // Expect delayed publisher-driven mutation.
        #expect(store.state.values == [10])
    }

    // Call async callback with and without animation.
    // Expect animation forwarding is preserved.
    @Test
    func asyncActionCallbackCallAsFunctionPropagatesAnimation() {
        // Set up callback capture.
        var captured: [(value: Int, hasAnimation: Bool)] = []
        let callback = NestedTaskGapNsp.Store.Effect.AsyncActionCallback { action, animation in
            guard case .mutating(.append(let value), _, _) = action else { return }
            captured.append((value: value, hasAnimation: animation != nil))
        }

        // Trigger both callback overloads.
        callback(.mutating(.append(1)))
        callback(.mutating(.append(2)), .default)

        // Expect forwarded values and animation metadata.
        #expect(captured.count == 2)
        #expect(captured[0].value == 1)
        #expect(!captured[0].hasAnimation)
        #expect(captured[1].value == 2)
        #expect(captured[1].hasAnimation)
    }

    // MARK: - Logging Paths

    // Enable all logging flags and mutate state.
    // Expect reducer behavior is unchanged.
    @Test
    func loggingFlagsEnabledStillPreserveReducerBehavior() {
        // Set up store with logging flags.
        let store = NestedTaskGapNsp.store()
        store.logConfig.logActionCallSite = true
        store.logConfig.logActions = true
        store.logConfig.logState = true

        // Trigger mutation under logging.
        store.send(.mutating(.append(11)))

        // Expect logging enabled and mutation applied.
        #expect(store.logConfig.logEnabled)
        #expect(store.state.values == [11])
    }

    // Log user actions across user and code paths.
    // Expect only user-initiated publish/effect/cancel are logged.
    @Test
    func logUserActionsClassifiesUserActionsOnly() async {
        // Set up store and action log.
        let store = NestedTaskGapNsp.store()
        var actionLog: [String] = []
        store.logConfig.logUserActions = { actionName, _ in
            actionLog.append(actionName)
        }

        // Trigger code, user effect, user publish, none, and cancel.
        _ = store.addEffect(.action(.mutating(.append(99))))
        let effectTask = store.send(.effect(.spawnAsync(1)))
        await effectTask?.value
        store.send(.publish("ready"))
        store.send(.none)
        store.send(.cancel)

        // Expect only user effect/publish/cancel entries.
        #expect(actionLog.count == 3)
        #expect(actionLog.contains(where: { $0.contains("spawnAsync") }))
        #expect(actionLog.contains(where: { $0.contains("publish") }))
        #expect(actionLog.contains(where: { $0.contains("cancel") }))
    }

}

extension LifecycleTests {
    @Suite @MainActor struct StateStoreLifecycleCoverageTests {}
}

extension LifecycleTests.StateStoreLifecycleCoverageTests {
    // Enable lifecycle debug logging and cancel store.
    // Expect lifecycle event tracking still works.
    @Test
    func lifecycleDebugLoggingStillTracksCancelEvent() {
        // Set up lifecycle log state.
        let originalLog = storeLifecycleLog
        defer { storeLifecycleLog = originalLog }
        storeLifecycleLog.enabled = true
        storeLifecycleLog.debug = true
        storeLifecycleLog.exclude = { _ in false }

        // Trigger allocate and cancel.
        let store = NestedTaskGapNsp.store()
        let storeID = store.id
        store.cancel()

        // Expect cancelled event tracked.
        #expect(storeLifecycleLog.lastEvent[storeID]?.event == "Cancelled")
    }
}
