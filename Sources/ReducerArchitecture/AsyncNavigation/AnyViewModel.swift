//
//  AnyViewModel.swift
//
//  Created by Codex.
//

import Foundation
import Combine
import CombineEx

@MainActor
public protocol AnyViewModel: AnyObject, Hashable, Identifiable {
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

    nonisolated static var storeDefaultKey: String { get }
}

public extension AnyViewModel {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
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
