//
//  AnyViewModel.swift
//
//  Created by Codex.
//

import Foundation
import Combine
import CombineEx

@MainActor
public protocol AnyViewModel: ObservableObject, Hashable, Identifiable {
    associatedtype PublishedValue

    nonisolated var id: UUID { get }
    nonisolated var name: String { get }
    var isCancelled: Bool { get }
    var publishedValue: PassthroughSubject<PublishedValue, Cancel> { get }
    func publish(_ value: PublishedValue)
    func cancel()

    /// Indicates whether there is request for a published value.
    ///
    /// Useful for testing navigation flows.
    var hasRequest: Bool { get set }

    nonisolated static var viewModelDefaultKey: String { get }

    /// Storage for child view models
    var children: [String: any AnyViewModel] { get set }

    func sendObjectWillChange()
}

public extension AnyViewModel {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
    }
}

extension AnyViewModel where Self.ObjectWillChangePublisher == ObservableObjectPublisher {
    public func sendObjectWillChange() {
        objectWillChange.send()
    }
}

// MARK: - Child view models

extension AnyViewModel {
    /// Adds a child to the store. The store must not already contain a child with the provided `key`.
    public func addChild<VM: AnyViewModel>(_ child: VM, key: String = VM.viewModelDefaultKey) {
        assert(children[key] == nil)
        sendObjectWillChange()
        children[key] = child
    }

    /// Removes a child from the store. If not `nil`, `child` must be a child of the store
    /// - Parameters:
    ///   - child: The child store to be removed.
    ///   - delay: Whether to delay the actual removal until the next UI update.
    ///
    ///  `delay` is useful to allow animated transitions for removing the UI for `child`.
    public func removeChild(_ child: (any AnyStore)?, delay: Bool = true) {
        guard let child else { return }
        sendObjectWillChange()
        child.cancel()
        if delay {
            DispatchQueue.main.async {
                self.removeChildImpl(child)
            }
        }
        else {
            removeChildImpl(child)
        }
    }

    private func removeChildImpl(_ child: (any AnyStore)?) {
        guard let child else { return }
        assert(child.isCancelled)
        guard let index = children.firstIndex(where: { $1 === child }) else { return }
        children.remove(at: index)
    }

    /// Adds a child to the store. If the store already contains a child with the provided `key`, the child store
    /// expression is not evaluated.
    public func addChildIfNeeded<T>(_ child: @autoclosure () -> StateStore<T>, key: String = StateStore<T>.viewModelDefaultKey) {
        if children[key] == nil {
            addChild(child())
        }
    }

    /// Returns a child store with a specific `key`.
    ///
    /// A child store should not be saved in `@State` or `@ObjectState` of a view because that creates a retain cycle:
    /// View State -> Store -> Store Environmemnt -> View State or
    /// Child View State -> Child Store -> Child Store Environment -> Child View State
    /// The retain cycle is there even with @ObservedObject because then SwiftUI View State still adds a reference to
    /// the store.
    ///
    /// The only way to break the retain cycle is to set the store environment to nil by cancelling the store. (Setting
    /// the store environment to nil directly is dangerous because the store might still receive messages after that but
    /// when the store is cancelled those messages are automatically ignored.)
    ///
    /// This is done automatically when a store is popped from the navigation stack or when its sheet is dismissed.
    /// However, if a child store is not retained by the store itself and is saved via the view state instead, the child
    /// store is not cancelled. Using the `child` APIs allows the child store to be cancelled automatically when its
    /// parent store is cancelled manually or as a result of going out of scope.
    ///
    /// Example:
    /// ```Swift
    /// private var childStore: ChildStoreNsp.Store { store.child()! }
    ///
    /// public init(store: Store) {
    ///    self.store = store
    ///    store.addChildIfNeeded(ChildStoreNsp.store())
    /// }
    /// ```
    public func child<T>(key: String = StateStore<T>.viewModelDefaultKey) -> StateStore<T>? {
        children[key] as? StateStore<T>
    }

    public func anyChild(key: String) -> (any AnyViewModel)? {
        children[key]
    }

    /// Runs a child store until it produces the first value
    public func run<T>(_ child: StateStore<T>, key: String = StateStore<T>.viewModelDefaultKey) async throws -> T.PublishedValue {
        addChild(child, key: key)
        defer { removeChild(child) }
        return try await child.firstValue()
    }
}

// MARK: - Published values helpers

public extension AnyViewModel {
    typealias ValuePublisher = AnyPublisher<PublishedValue, Cancel>

    var value: AnyPublisher<PublishedValue, Cancel> {
        publishedValue
            .handleEvents(
                receiveOutput: { [weak self] _ in
                    assert(Thread.isMainThread)
                    self?.hasRequest = false
                },
                receiveRequest: { [weak self] _ in
                    assert(Thread.isMainThread)
                    self?.hasRequest = true
                }
            )
            .subscribe(on: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }

    var valueResult: AnyPublisher<Result<PublishedValue, Cancel>, Never> {
        value
            .map { .success($0) }
            .catch { Just(.failure($0)) }
            .eraseToAnyPublisher()
    }

    var throwingAsyncValues: AsyncThrowingPublisher<AnyPublisher<PublishedValue, Cancel>> {
        value.values
    }

    var asyncValues: AsyncPublisher<AnyPublisher<PublishedValue, Never>> {
        value
            .catch { _ in Empty<PublishedValue, Never>() }
            .eraseToAnyPublisher()
            .values
    }

    func get(callback: @escaping (PublishedValue) async throws -> Void) async throws {
        try await asyncValues.get(callback: callback)
    }

    func get(callback: @escaping (PublishedValue) async -> Void) async {
        await asyncValues.get(callback: callback)
    }

    func getFirst(callback: @escaping (PublishedValue) async throws -> Void) async throws {
        let firstValue = try await value.first().async()
        try await callback(firstValue)
    }

    func getFirst(callback: @escaping (PublishedValue) async -> Void) async {
        if let firstValue = try? await value.first().async() {
            await callback(firstValue)
        }
    }

    func firstValue() async throws -> PublishedValue {
        defer { cancel() }
        return try await value.first().async()
    }

    /// A convenience API to avoid a race condition between the code that needs a first value
    /// and the code that provides it.
    func getRequest() async {
        while !hasRequest {
            await Task.yield()
        }
    }

    func publish(_ value: PublishedValue) {
        publishedValue.send(value)
    }

    func cancel() {
        publishedValue.send(completion: .failure(.cancel))
    }

    var isCancelledPublisher: AnyPublisher<Void, Never> {
        publishedValue
            .map { _ in false }
            .replaceError(with: true)
            .filter { $0 }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}
