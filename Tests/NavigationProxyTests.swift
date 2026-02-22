import Testing
#if canImport(SwiftUI)
import SwiftUI
@testable import ReducerArchitecture
@testable import TestSupport

@MainActor
private final class HybridStoreNamespaceViewModel: BaseViewModel<Void>, StoreNamespace {
    typealias StoreEnvironment = Never
    typealias MutatingAction = Void
    typealias EffectAction = Never

    struct StoreState: Equatable {}
}

private enum HybridStoreNamespaceUI: ViewModelUINamespace {
    typealias ViewModel = HybridStoreNamespaceViewModel

    struct ContentView: ViewModelContentView {
        let viewModel: ViewModel

        init(_ viewModel: ViewModel) {
            self.viewModel = viewModel
        }

        var body: some View {
            EmptyView()
        }
    }
}

@Suite @MainActor
struct NavigationProxyTests {}

extension NavigationProxyTests {
    // MARK: - Store Lookup

    // Read view model using StoreNamespace overload.
    // Expect typed view model and index advance.
    @Test
    func getStoreForStoreNamespaceReturnsTypedValueAndAdvancesIndex() async throws {
        // Set up proxy and pushed hybrid view model.
        let proxy = TestNavigationProxy()
        let expected = HybridStoreNamespaceViewModel()
        _ = proxy.push(ViewModelUI<HybridStoreNamespaceUI>(expected))
        var timeIndex = 0

        // Trigger typed lookup.
        let viewModel = try await proxy.getStore(HybridStoreNamespaceViewModel.self, &timeIndex)

        // Expect typed result and incremented index.
        #expect(viewModel === expected)
        #expect(timeIndex == 1)
    }

    // Read StoreNamespace with mismatched type.
    // Expect type-mismatch error.
    @Test
    func getStoreForStoreNamespaceThrowsOnTypeMismatch() async {
        // Set up proxy with different pushed view model.
        let proxy = TestNavigationProxy()
        _ = proxy.push(StoreUI(store: IntPicker.store()))
        var timeIndex = 0

        // Trigger mismatched lookup.
        await expectTypeMismatch {
            _ = try await proxy.getStore(HybridStoreNamespaceViewModel.self, &timeIndex)
        }
    }

    // Read StoreUINamespace with mismatched view model.
    // Expect type-mismatch error.
    @Test
    func getStoreForStoreUINamespaceThrowsOnTypeMismatch() async {
        // Set up proxy with wrong StoreUI namespace.
        let proxy = TestNavigationProxy()
        _ = proxy.push(StoreUI(store: IntPicker.store()))
        var timeIndex = 0

        // Trigger mismatched lookup.
        await expectTypeMismatch {
            _ = try await proxy.getStore(StringPicker.self, &timeIndex)
        }
    }

    private func expectTypeMismatch(
        _ operation: () async throws -> Void
    ) async {
        var didCatchTypeMismatch = false
        var didCatchUnexpectedError = false

        do {
            try await operation()
        }
        catch let error as TestNavigationProxy.CurrentViewModelError {
            switch error {
            case .typeMismatch:
                didCatchTypeMismatch = true
            }
        }
        catch {
            didCatchUnexpectedError = true
        }

        #expect(didCatchTypeMismatch)
        #expect(!didCatchUnexpectedError)
    }
}
#endif
