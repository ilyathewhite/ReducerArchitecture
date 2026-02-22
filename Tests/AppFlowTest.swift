//
//  AppFlowTest.swift
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import Testing
@testable import ReducerArchitecture
@testable import TestSupport

@Suite @MainActor
struct AppFlowTests {}

extension AppFlowTests {
    // MARK: - Race Conditions

    // Run all flow scenarios repeatedly.
    // Expect no navigation race conditions.
    @Test
    func repeatedFlowRunsDoNotRace() async throws {
        // Set up iteration count.
        let iterations = 1_000

        // Trigger all scenarios repeatedly.
        for _ in 0..<iterations {
            try await runPairFlow()
            try await runPairFlowWithBacktracking()
            try await runPairFlowBackToRoot()
            try await runConcatenateFlow()
            try await runConcatenateFlowWithBacktracking()
        }
    }

    // Run Pair flow end to end.
    // Expect final Pair result and return to root.
    @Test
    func pairFlowCompletesWithExpectedResult() async throws {
        // Trigger and expect Pair flow behavior.
        try await runPairFlow()
    }

    // Run Pair flow with back navigation.
    // Expect resumed flow uses updated values.
    @Test
    func pairFlowSupportsBacktracking() async throws {
        // Trigger and expect Pair backtracking behavior.
        try await runPairFlowWithBacktracking()
    }

    // Start Pair flow then back out early.
    // Expect flow exits to root.
    @Test
    func pairFlowCanExitEarlyToRoot() async throws {
        // Trigger and expect Pair early-exit behavior.
        try await runPairFlowBackToRoot()
    }

    // Run Concatenate flow end to end.
    // Expect delimiter-joined result and return to root.
    @Test
    func concatenateFlowCompletesWithExpectedResult() async throws {
        // Trigger and expect Concatenate flow behavior.
        try await runConcatenateFlow()
    }

    // Run Concatenate flow with multiple back steps.
    // Expect final result reflects latest backtracked values.
    @Test
    func concatenateFlowSupportsBacktracking() async throws {
        // Trigger and expect Concatenate backtracking behavior.
        try await runConcatenateFlowWithBacktracking()
    }

    // Run unsupported flow.
    // Expect fallback result and return to root.
    @Test
    func unknownFlowShowsFallbackResult() async throws {
        // Set up navigation proxy and root.
        let navigationProxy = TestNavigationProxy()
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = navigationProxy.push(StoreUI(store: rootStore))

        let flow = AppFlow(flow: "unsupported", proxy: navigationProxy)
        let flowTask = Task {
            await flow.run()
        }
        var timeIndex = 1

        // Trigger fallback path.
        let resultStore = try await navigationProxy.getStore(Done.self, &timeIndex)
        await resultStore.publishOnRequest(())

        // Expect fallback output and root restore.
        #expect(resultStore.state.value == "Unknown Flow")
        let restoredRoot = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredRoot == rootStore)
        await flowTask.value
    }

    private func runPairFlow() async throws {
        // Set up navigation proxy and root.
        let navigationProxy = TestNavigationProxy()
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = navigationProxy.push(StoreUI(store: rootStore))

        let flow = AppFlow(flow: "Pair", proxy: navigationProxy)
        let flowTask = Task {
            await flow.run()
        }
        var timeIndex = 1

        // Trigger int and string picks.
        let intPickerStore = try await navigationProxy.getStore(IntPicker.self, &timeIndex)
        await intPickerStore.publishOnRequest(2)

        let stringPickerStore = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPickerStore.send(.mutating(.updateValue("hello")))
        await stringPickerStore.publishOnRequest(stringPickerStore.state.value)

        // Expect result and root restore.
        let resultStore = try await navigationProxy.getStore(Done.self, &timeIndex)
        #expect(resultStore.state.value == "2, hello")
        await resultStore.publishOnRequest(())

        let restoredRoot = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredRoot == rootStore)
        await flowTask.value
    }

    private func runPairFlowWithBacktracking() async throws {
        // Set up navigation proxy and root.
        let navigationProxy = TestNavigationProxy()
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = navigationProxy.push(StoreUI(store: rootStore))

        let flow = AppFlow(flow: "Pair", proxy: navigationProxy)
        let flowTask = Task {
            await flow.run()
        }
        var timeIndex = 1

        // Trigger first int pick.
        let intPickerStore = try await navigationProxy.getStore(IntPicker.self, &timeIndex)
        await intPickerStore.publishOnRequest(2)

        // Trigger first string pick then go back.

        let stringPickerStore = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPickerStore.send(.mutating(.updateValue("hello")))
        navigationProxy.backAction()

        // Trigger updated picks.
        let restoredIntPicker = try await navigationProxy.getStore(IntPicker.self, &timeIndex)
        #expect(restoredIntPicker == intPickerStore)
        await intPickerStore.publishOnRequest(3)

        let nextStringPickerStore = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        nextStringPickerStore.send(.mutating(.updateValue("hi")))
        await nextStringPickerStore.publishOnRequest(nextStringPickerStore.state.value)

        // Expect result and root restore.
        let resultStore = try await navigationProxy.getStore(Done.self, &timeIndex)
        #expect(resultStore.state.value == "3, hi")
        await resultStore.publishOnRequest(())

        let restoredRoot = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredRoot == rootStore)
        await flowTask.value
    }

    private func runPairFlowBackToRoot() async throws {
        // Set up navigation proxy and root.
        let navigationProxy = TestNavigationProxy()
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = navigationProxy.push(StoreUI(store: rootStore))

        let flow = AppFlow(flow: "Pair", proxy: navigationProxy)
        let flowTask = Task {
            await flow.run()
        }
        var timeIndex = 1

        // Trigger first screen then back out.
        let intPickerStore = try await navigationProxy.getStore(IntPicker.self, &timeIndex)
        intPickerStore.send(.mutating(.updateValue(1)))
        navigationProxy.backAction()

        // Expect return to root.
        let restoredRoot = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredRoot == rootStore)
        await flowTask.value
    }

    private func runConcatenateFlow() async throws {
        // Set up navigation proxy and root.
        let navigationProxy = TestNavigationProxy()
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = navigationProxy.push(StoreUI(store: rootStore))

        let flow = AppFlow(flow: "Concatenate", proxy: navigationProxy)
        let flowTask = Task {
            await flow.run()
        }
        var timeIndex = 1

        // Trigger count and delimiter picks.
        let stringCountStore = try await navigationProxy.getStore(IntPicker.self, &timeIndex)
        await stringCountStore.publishOnRequest(3)

        let delimiterPickerStore = try await navigationProxy.getStore(DelimiterPicker.self, &timeIndex)
        await delimiterPickerStore.publishOnRequest(.pipe)

        // Trigger string picks.
        let stringPicker1 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker1.send(.mutating(.updateValue("one")))
        await stringPicker1.publishOnRequest(stringPicker1.state.value)

        let stringPicker2 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker2.send(.mutating(.updateValue("two")))
        await stringPicker2.publishOnRequest(stringPicker2.state.value)

        let stringPicker3 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker3.send(.mutating(.updateValue("three")))
        await stringPicker3.publishOnRequest(stringPicker3.state.value)

        // Expect result and root restore.
        let resultStore = try await navigationProxy.getStore(Done.self, &timeIndex)
        #expect(resultStore.state.value == "one|two|three")
        await resultStore.publishOnRequest(())

        let restoredRoot = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredRoot == rootStore)
        await flowTask.value
    }

    private func runConcatenateFlowWithBacktracking() async throws {
        // Set up navigation proxy and root.
        let navigationProxy = TestNavigationProxy()
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = navigationProxy.push(StoreUI(store: rootStore))

        let flow = AppFlow(flow: "Concatenate", proxy: navigationProxy)
        let flowTask = Task {
            await flow.run()
        }
        var timeIndex = 1

        // Trigger count and initial delimiter picks.
        let stringCountStore = try await navigationProxy.getStore(IntPicker.self, &timeIndex)
        await stringCountStore.publishOnRequest(3)

        let delimiterPickerStore = try await navigationProxy.getStore(DelimiterPicker.self, &timeIndex)
        await delimiterPickerStore.publishOnRequest(.pipe)

        // Trigger first string then back to delimiter.

        let stringPicker1 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker1.send(.mutating(.updateValue("one")))
        navigationProxy.backAction()

        let restoredDelimiterPicker = try await navigationProxy.getStore(DelimiterPicker.self, &timeIndex)
        #expect(restoredDelimiterPicker == delimiterPickerStore)
        await delimiterPickerStore.publishOnRequest(.dash)

        // Trigger second string.
        let stringPicker2 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker2.send(.mutating(.updateValue("two")))
        await stringPicker2.publishOnRequest(stringPicker2.state.value)

        // Trigger third string then back to second.

        let stringPicker3 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker3.send(.mutating(.updateValue("three")))
        navigationProxy.backAction()

        let restoredStringPicker2 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredStringPicker2 == stringPicker2)
        stringPicker2.send(.mutating(.updateValue("_three")))
        await stringPicker2.publishOnRequest(stringPicker2.state.value)

        // Trigger fourth and fifth strings then back to fourth.

        let stringPicker4 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker4.send(.mutating(.updateValue("four")))
        await stringPicker4.publishOnRequest(stringPicker4.state.value)

        let stringPicker5 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker5.send(.mutating(.updateValue("five")))
        navigationProxy.backAction()

        let restoredStringPicker4 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredStringPicker4 == stringPicker4)
        stringPicker4.send(.mutating(.updateValue("four")))
        await stringPicker4.publishOnRequest(stringPicker4.state.value)

        // Trigger sixth string.
        let stringPicker6 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        stringPicker6.send(.mutating(.updateValue("six")))
        await stringPicker6.publishOnRequest(stringPicker6.state.value)

        // Trigger result then back to sixth.

        _ = try await navigationProxy.getStore(Done.self, &timeIndex)
        navigationProxy.backAction()

        let restoredStringPicker6 = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredStringPicker6 == stringPicker6)
        stringPicker6.send(.mutating(.updateValue("_six")))
        await stringPicker6.publishOnRequest(stringPicker6.state.value)

        // Expect final result and root restore.
        let resultStore = try await navigationProxy.getStore(Done.self, &timeIndex)
        #expect(resultStore.state.value == "_three-four-_six")
        await resultStore.publishOnRequest(())

        let restoredRoot = try await navigationProxy.getStore(StringPicker.self, &timeIndex)
        #expect(restoredRoot == rootStore)
        await flowTask.value
    }
}
