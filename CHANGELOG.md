# Changelog

## 2.0.1

This release completes the Swift 6 migration started in 2.0.0. Despite the patch version,
explicitly typed async effect closures may require source changes; see the migration notes below.

- Require FoundationEx 1.1.0, GraphStorage 1.1.0, and AsyncNavigation 2.0.1.
- Work around Swift's generic isolated-deinitializer optimizer crash on compilers before 6.4
  ([swiftlang/swift#87462](https://github.com/swiftlang/swift/issues/87462)). Disable optimization only for the
  affected deinitializers, preserving main-actor cleanup, deployment targets, and optimization elsewhere.
- Build the package and its tests in Swift 6 language mode, retaining the Swift 6.2 toolchain requirement.
- Isolate async effect closures and `AsyncActionCallback` to the main actor. State, environments, and actions
  can remain non-`Sendable`.
- Buffer callback-produced actions with `MainActorValueSource`, keeping their payloads on the main actor.
- Preserve `.publisher` effects and publisher observation/binding APIs. Publisher effects now deliver upstream
  emissions through the main queue, and cancel their subscriptions on the main actor.

### Migration from 2.0.0

Inline async effect closures continue to infer their isolation. Add `@MainActor` to explicitly typed closures
passed to `.asyncAction`, `.asyncActionLatest`, `.asyncActions`, `.asyncActionSequence`, or
`.asyncActionSequenceLatest`. Invoke `AsyncActionCallback` on the main actor.

## 2.0.0

- Require Swift tools 6.2, iOS 18, macOS 15, and tvOS 18; retain Swift 5 language mode.
- Depend on AsyncNavigation 2.0.0 and remove the CombineEx dependency.
- Require `StoreNamespace.PublishedValue: Sendable`.
- Implement store-to-store `bind` and `bindPublishedValue` with native async sequences and store-owned effects.
- Register bindings synchronously so mutations and outputs immediately following `bind` cannot be missed.
- Keep initial state delivery, distinct-value filtering, animation, tracing, cancellation, and ordered burst delivery.
- Keep state observations on the main actor without requiring state or observed values to conform to `Sendable`.
- Make SwiftUI `store.binding` capture the store weakly. After release, reads keep the last value observed
  through the binding and writes are ignored.
- Make `readOnlyBinding` capture the store weakly and keep its last observed value after release.
- Release temporary store references before `.asyncAction` and `.asyncActionLatest` await nested effects,
  so long-lived observations do not prevent store deallocation.
- Preserve `.publisher` effects and the `values`, `updates`, and `distinctValues` publisher APIs.
- Add `.asyncSequence(sequence, animation)` effects for nonthrowing async sequences of actions, including
  Async Algorithms pipelines. Subscription starts when the effect is added; iteration and action delivery
  stay on the main actor and follow the store's lifetime.
- Add main-actor async-sequence overloads of `values(on:)`, `distinctValues(on:)`, and `updates(on:)`,
  including custom-comparison overloads. Duplicate filtering uses Async Algorithms; updates skip the initial value.
- Retain `asyncValues(on:)` with a native implementation; the async `values(on:)` overload forwards to it.
- Propagate cancellation of the task returned by async action sequence effects to their producer and consumer,
  so callers can stop an observation without cancelling the store.
- Preserve synchronous state-publisher delivery and completion on store cancellation.

### Migration

Add checked `Sendable` conformances to published output models. Store state and action models do not acquire a
new `Sendable` requirement. Existing `bind` and `bindPublishedValue` call sites continue to work.
Binding delivery is asynchronous. Awaiting a source effect does not wait for its values to reach another store;
tests that assert the destination state should wait for that state to arrive.

`asyncValues(on:)` keeps its name and now returns `MainActorSequence<Value>` instead of `AsyncStream<Value>`.
Consume it on the main actor with `for await`. The new async `values(on:)` overload provides the same sequence,
for example with `for await value in store.values(on: keyPath)`.
Each iterator receives the current value followed by every mutation until the source store is cancelled or destroyed.
For distinct values including the initial value, use `store.distinctValues(on:)`; for subsequent distinct changes,
use `store.updates(on:)`. Both support `compare:`. Custom comparisons run on the main actor, and observed values
do not need to be `Sendable`. Publisher contexts such as `.onReceive` and `.sink`
select the existing Combine overload. When storing the result without a consuming context, specify
`MainActorSequence<Value>` or `AnyPublisher<Value, Never>` to select the desired overload.
Store-state binding completion leaves the target alive. Cancellation of a published-output source still cancels
the target; cancelling a target or its binding task only detaches that observation.

Replace direct subject subscriptions with `store.asyncValues` / `store.throwingAsyncValues`, or use `store.value`
for Combine interoperability. See AsyncNavigation's 2.0.0 migration notes for custom view models and test proxies.

Use `.asyncSequence(values.map { .mutating(...) })` when a dependency already supplies an async sequence.
The effect supports optional animation, ordered action delivery, and session tracing without requiring
actions to be `Sendable`. It subscribes before returning from `addEffect`, finishes when its source ends,
and cancels with the store or its returned task. Source completion leaves the store active. Awaiting the
task also waits for effects started by emitted actions; those effects do not block later sequence actions.
Existing `.asyncActionSequence { send in ... }` effects remain available for callback-based action production.
