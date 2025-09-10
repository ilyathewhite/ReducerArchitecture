# Reducer Architecture

TRA (the reducer architecture) is inspired by a very early version of TCA.

## Key Differences from TCA
While both frameworks are based on the same idea of having a store, state, and a reducer function, they differ quite a bit in the implementation details.

- **Two action kinds (mutating vs. effect)**<br>
  TRA encodes this distinction in the type system so only mutating actions can change state (and thus trigger view updates).
  Whether an action is mutating is clear at the call site (similar to let / var in Swift), which is useful for reasoning
  about the code. <br>
  TCA has a single action enum. This isn't a performance issue in the latest version of TCA that uses Swift Observation framework,
  but an older vesion that used `@ObservableObject` had more view updates because any action triggered a view update.
- **Store ownership vs. single source of truth**<br>
  TRA uses multiple stores, and each store owns its state. Parents can subscribe to slices of child state without owning it.<br>
  TCA encourages a single root state tree composed via scoping (you can do “islands”, but the canonical model is a
  single tree.)
- **Reducer composition direction**<br>
  TRA: parent stores know about child stores and subscribe to what they need, avoiding tight coupling to child internals.<br>
  TCA: parent state contains child state; reducers are composed via `Scope/forEach/ifLet`.
- **Effect lifetime management**<br>
  TRA ties long-running tasks to the lifetime of the store that started them (auto-cancels on teardown).<br>
  TCA supports automatic cancellation for scoped lifetimes (e.g., ifLet, forEach, presentation) and explicit cancellation
  via IDs elsewhere. TRA makes this the default everywhere.
- **Navigation model**<br>
  TRA models navigation with Swift concurrency (imperative flows like `await showForm()`), which is ergonomically close to
  how we think about flows.<br>
  TCA: navigation is state-driven (`@PresentationState/PresentationAction`) to maximize testability, persistence,
  and deep-linking. TRA trades some of that for simpler control flow.
- **Surface area & macros**<br>
  TRA keeps the API small and avoids macros.<br>
  TCA: the recommended style uses macros (`@Reducer`, `@ObservableState`, `@Dependency`, `@PresentationState`)
  but they’re optional —- non-macro forms still exist.

## Example
To see TRA in action and compare it to TCA, check the SyncUps example:<br>
- [TRA implementation](https://github.com/ilyathewhite/SyncUpsTRA)
- [TCA implementation](https://github.com/pointfreeco/swift-composable-architecture/tree/main/Examples/SyncUps)
