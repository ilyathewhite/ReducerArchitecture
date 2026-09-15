# Changelog

## 2.0.0

- Require Swift tools 6.2, iOS 18, macOS 15, and tvOS 18; retain Swift 5 language mode.
- Depend on AsyncNavigation 2.0.0 and remove the CombineEx dependency.
- Require `StoreNamespace.PublishedValue: Sendable`.
- Implement store-to-store `bind` and `bindPublishedValue` with native async sequences and store-owned effects.
- Register bindings synchronously so mutations and outputs immediately following `bind` cannot be missed.
- Keep initial state delivery, distinct-value filtering, animation, tracing, cancellation, and ordered burst delivery.
- Keep state observations on the main actor without requiring state or observed values to conform to `Sendable`.
- Preserve `.publisher` effects and the `values`, `updates`, and `distinctValues` publisher APIs.
- Preserve synchronous state-publisher delivery and completion on store cancellation.

### Migration

Add checked `Sendable` conformances to published output models. Store state and action models do not acquire a
new `Sendable` requirement. Existing `bind` and `bindPublishedValue` call sites continue to work.

`asyncValues(on:)` now returns `MainActorSequence<Value>`. Consume it on the main actor with `for await`.
Each iterator receives the current value followed by every mutation until the source store is cancelled or destroyed.
Store-state binding completion leaves the target alive. Cancellation of a published-output source still cancels
the target; cancelling a target or its binding task only detaches that observation.

Replace direct subject subscriptions with `store.asyncValues` / `store.throwingAsyncValues`, or use `store.value`
for Combine interoperability. See AsyncNavigation's 2.0.0 migration notes for custom view models and test proxies.
