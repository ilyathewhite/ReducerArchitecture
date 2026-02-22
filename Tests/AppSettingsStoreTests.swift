import Testing
@testable import ReducerArchitecture

private struct TestAppSettingsState: AppSettingsStoreStateType {
    var username = "guest"
    var launchCount = 0

    init() {}
}

private typealias TestAppSettingsNsp = AppSettingsNsp<TestAppSettingsState>
private typealias TestAppSettingsStore = TestAppSettingsNsp.Store

extension AppSettingsTests {
    @Suite @MainActor struct AppSettingsStoreTests {}
}

extension AppSettingsTests.AppSettingsStoreTests {
    // MARK: - Mutations

    // Set username through setAction.
    // Expect only username changes.
    @Test
    func setActionUpdatesOnlyTargetKeyPath() {
        // Set up state and action.
        var state = TestAppSettingsState()
        let action = TestAppSettingsNsp.setAction(\.username, "ilya")

        // Trigger reducer update.
        _ = TestAppSettingsNsp.reduce(&state, action)

        // Expect only requested key-path mutated.
        #expect(state.username == "ilya")
        #expect(state.launchCount == 0)
    }

    // Build set actions with and without animation.
    // Expect animation metadata only on animated action.
    @Test
    func actionSetIncludesAnimationOnlyWhenProvided() {
        // Set up actions.
        let nonAnimated = TestAppSettingsStore.Action.set(\.launchCount, 1)
        let animated = TestAppSettingsStore.Action.set(\.launchCount, 2, animation: .default)

        // Trigger action pattern matching.
        let nonAnimatedIsMutating: Bool
        let nonAnimatedIsAnimated: Bool
        let nonAnimatedAnimationIsNil: Bool
        switch nonAnimated {
        case .mutating(_, let isAnimated, let animation):
            nonAnimatedIsMutating = true
            nonAnimatedIsAnimated = isAnimated
            nonAnimatedAnimationIsNil = (animation == nil)
        default:
            nonAnimatedIsMutating = false
            nonAnimatedIsAnimated = false
            nonAnimatedAnimationIsNil = false
        }

        let animatedIsMutating: Bool
        let animatedIsAnimated: Bool
        let animatedAnimationIsNil: Bool
        switch animated {
        case .mutating(_, let isAnimated, let animation):
            animatedIsMutating = true
            animatedIsAnimated = isAnimated
            animatedAnimationIsNil = (animation == nil)
        default:
            animatedIsMutating = false
            animatedIsAnimated = false
            animatedAnimationIsNil = true
        }

        // Expect animation metadata shape.
        #expect(nonAnimatedIsMutating)
        #expect(nonAnimatedIsAnimated == false)
        #expect(nonAnimatedAnimationIsNil)
        #expect(animatedIsMutating)
        #expect(animatedIsAnimated == true)
        #expect(!animatedAnimationIsNil)
    }

    // Call store.set on launchCount.
    // Expect reducer writes value.
    @Test
    func storeSetWritesValueThroughReducer() {
        // Set up store.
        let store = TestAppSettingsNsp.store()

        // Trigger setting update.
        store.set(\.launchCount, 7)

        // Expect state change.
        #expect(store.state.launchCount == 7)
    }

    // Write same then changed value through binding.
    // Expect only changed write is logged.
    @Test
    func bindingSkipsNoOpWriteAndAppliesChangedValue() {
        // Set up store, logger, and binding.
        let store = TestAppSettingsNsp.store()
        var actionLog: [String] = []
        store.logConfig.logUserActions = { actionName, _ in
            actionLog.append(actionName)
        }
        let binding = store.binding(\.username)

        // Trigger no-op then real update.
        binding.wrappedValue = "guest"
        binding.wrappedValue = "admin"

        // Expect state update and one user action.
        #expect(store.state.username == "admin")
        #expect(actionLog.count == 1)
    }
}
