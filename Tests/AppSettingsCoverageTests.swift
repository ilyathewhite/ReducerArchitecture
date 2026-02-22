import Testing
import SwiftUI
@testable import ReducerArchitecture

private struct GapAppSettingsState: AppSettingsStoreStateType {
    var username = "guest"
    var launchCount = 0

    init() {}
}

private typealias GapAppSettingsNsp = AppSettingsNsp<GapAppSettingsState>

extension AppSettingsTests {
    @Suite @MainActor struct AppSettingsCoverageTests {}
}

extension AppSettingsTests.AppSettingsCoverageTests {
    // MARK: - Optional Bindings

    // Bind AppSettings value as optional.
    // Expect optional binding reads and writes state.
    @Test
    func appSettingsOptionalBindingReadsAndWritesValue() {
        // Set up app settings store and optional binding.
        let store = GapAppSettingsNsp.store()
        let binding: Binding<Int?> = store.binding(\.launchCount)

        // Trigger optional binding write.
        #expect(binding.wrappedValue == 0)
        binding.wrappedValue = 9

        // Expect state updated through binding path.
        #expect(store.state.launchCount == 9)
        #expect(binding.wrappedValue == 9)
    }
}
