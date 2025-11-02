//
//  ReducerArchitectureTesting.swift
//
//  Created by Ilya Belenkiy on 3/18/23.
//

import Foundation
import FoundationEx

extension StateStore {
    public enum TestResult {
        case success
        case noSnapshots(URL)
        case noMutatingActions
        case decodingError(inputStep: Int)
        case stepInputMismatch(inputStep: Int)
        case stateChangeMismatch(inputStep: Int)
        case outputMismatch(inputStep: Int)
        
        public var isSuccess: Bool {
            switch self {
            case .success: return true
            default: return false
            }
        }
    }
    
    enum Comparison {
        case codeString
        case equatable
    }
    
    nonisolated
    static private func decode<T: Decodable>(_ data: Data?) -> T? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    
    @MainActor
    private func testAgainstSnapshots(
        startState: State,
        snapshotsURL: URL,
        maxStepCount: Int?,
        isMatchingStateChange: (_ inputStep: Int, State, ReducerSnapshotData.Output) -> (Comparison, TestResult),
        isMatchingOutput: (_ inputStep: Int, SyncEffect, ReducerSnapshotData.Output) -> (Comparison, TestResult)
    )
    -> TestResult
    where MutatingAction: Decodable
    {
        guard let snapshotCollection: ReducerSnapshotCollection = try? .load(from: snapshotsURL) else {
            return .noSnapshots(snapshotsURL)
        }
        
        func step(_ index: Int) -> Int {
            index + 1
        }
        
        var state = startState
        var index = 0
        var mutatingActionCount = 0
        var stateChangeComparison: Comparison?
        var outputComparison: Comparison?

        var stepCount = snapshotCollection.snapshots.count
        if let maxStepCount, maxStepCount < stepCount {
            stepCount = maxStepCount
        }
        
        while index < stepCount {
            switch snapshotCollection.snapshots[index] {
            case .input(let input):
                if let data = input.encodedMutatingAction {
                    mutatingActionCount += 1
                    guard let mutatingAction: MutatingAction = Self.decode(data) else {
                        return .decodingError(inputStep: step(index))
                    }
                    let syncEffect = reducer.run(&state, mutatingAction)
                    
                    // check state change
                    if index + 1 == snapshotCollection.snapshots.count {
                        return .decodingError(inputStep: step(index))
                    }
                    if !snapshotCollection.snapshots[index + 1].isStateChange {
                        return .decodingError(inputStep: step(index))
                    }
                    
                    if index + 2 == snapshotCollection.snapshots.count {
                        return .decodingError(inputStep: step(index))
                    }
                    
                    switch snapshotCollection.snapshots[index + 2] {
                    case .output(let output):
                        let (c1, stateResult) = isMatchingStateChange(step(index), state, output)
                        stateChangeComparison = c1
                        if !stateResult.isSuccess {
                            return stateResult
                        }
                        let (c2, outputResult) = isMatchingOutput(step(index), syncEffect, output)
                        outputComparison = c2
                        if !outputResult.isSuccess {
                            return outputResult
                        }
                        index += 3
                        
                    default:
                        return .decodingError(inputStep: step(index))
                    }
                }
                else if input.action.starts(with: ".mutating(") {
                    return .decodingError(inputStep: step(index))
                }
                else { // skip non-mutating action
                    index += 1
                }
            default:
                index += 1
            }
        }
        
        var testInfo = "\nTest compared \(mutatingActionCount) change(s)."
        if let stateChangeComparison {
            testInfo.append("\nCompared state using \(stateChangeComparison).")
        }
        if let outputComparison {
            testInfo.append("\nCompared output using \(outputComparison).")
        }
        logger.info("\(testInfo)")
        return mutatingActionCount > 0 ? .success : .noMutatingActions
    }
    
    nonisolated
    private static func isMatchingStateChange(inputStep: Int, state: State, output: ReducerSnapshotData.Output) -> (Comparison, TestResult)
    where State: Decodable & Equatable {
        let comparison: Comparison = .equatable
        guard let otherState: State = Self.decode(output.encodedState) else {
            return (comparison, .decodingError(inputStep: inputStep))
        }
        return (comparison, state == otherState ? .success : .stateChangeMismatch(inputStep: inputStep))
    }
    
    nonisolated
    private static func isMatchingStateChange(inputStep: Int, state: State, output: ReducerSnapshotData.Output) -> (Comparison, TestResult) {
        return (.codeString, propertyCodeStrings(state) == output.state ? .success : .stateChangeMismatch(inputStep: inputStep))
    }
    
    nonisolated
    private static func isMatchingOutput(inputStep: Int, effect: SyncEffect, output: ReducerSnapshotData.Output) -> (Comparison, TestResult)
    where SyncEffect: Decodable & Equatable {
        let comparison: Comparison = .equatable
        guard let otherEffect: SyncEffect = decode(output.encodedSyncEffect) else {
            return (comparison, .decodingError(inputStep: inputStep))
        }
        return (comparison, effect == otherEffect ? .success : .outputMismatch(inputStep: inputStep))
    }
    
    nonisolated
    private static func isMatchingOutput(inputStep: Int, effect: SyncEffect, output: ReducerSnapshotData.Output) -> (Comparison, TestResult) {
        return (.codeString, codeString(effect) == output.effect ? .success : .outputMismatch(inputStep: inputStep))
    }
    
    // 4 combinations of conformances to cover all cases. Otherwise, the compiler always picks the most general version.
    
    @MainActor
    public func testAgainstSnapshots(startState: State, snapshotsURL: URL, maxStepCount: Int? = nil) -> TestResult
    where MutatingAction: Decodable, State: Decodable & Equatable, SyncEffect: Decodable & Equatable {
        testAgainstSnapshots(
            startState: startState,
            snapshotsURL: snapshotsURL,
            maxStepCount: maxStepCount,
            isMatchingStateChange: Self.isMatchingStateChange,
            isMatchingOutput: Self.isMatchingOutput
        )
    }
    
    @MainActor
    public func testAgainstSnapshots(startState: State, snapshotsURL: URL, maxStepCount: Int? = nil) -> TestResult
    where MutatingAction: Decodable, State: Decodable & Equatable {
        testAgainstSnapshots(
            startState: startState,
            snapshotsURL: snapshotsURL,
            maxStepCount: maxStepCount,
            isMatchingStateChange: Self.isMatchingStateChange,
            isMatchingOutput: Self.isMatchingOutput
        )
    }
    
    @MainActor
    public func testAgainstSnapshots(startState: State, snapshotsURL: URL, maxStepCount: Int? = nil) -> TestResult
    where MutatingAction: Decodable, SyncEffect: Decodable & Equatable {
        testAgainstSnapshots(
            startState: startState,
            snapshotsURL: snapshotsURL,
            maxStepCount: maxStepCount,
            isMatchingStateChange: Self.isMatchingStateChange,
            isMatchingOutput: Self.isMatchingOutput
        )
    }
    
    @MainActor
    public func testAgainstSnapshots(startState: State, snapshotsURL: URL, maxStepCount: Int? = nil) -> TestResult
    where MutatingAction: Decodable {
        testAgainstSnapshots(
            startState: startState,
            snapshotsURL: snapshotsURL,
            maxStepCount: maxStepCount,
            isMatchingStateChange: Self.isMatchingStateChange,
            isMatchingOutput: Self.isMatchingOutput
        )
    }
}

#if canImport(SwiftUI)
import SwiftUI

public enum NavigationEnvRootTestStoreNsp: StoreNamespace, ViewModelNamespace {
    public typealias PublishedValue = Void
    
    public typealias StoreEnvironment = Never
    public typealias MutatingAction = Void
    public typealias EffectAction = Never
    
    public struct StoreState {
        let actionName: String
    }
}

public extension NavigationEnvRootTestStoreNsp {
    @MainActor
    static func store(actionName: String) -> Store {
        Store(.init(actionName: actionName), reducer: reducer())
    }
}

extension NavigationEnvRootTestStoreNsp: StoreUINamespace, ViewModelUINamespace {
    public struct ContentView: StoreContentView {
        public typealias Nsp = NavigationEnvRootTestStoreNsp
        @ObservedObject public var store: Store
        
        public init(store: Store) {
            self.store = store
        }
        
        public var body: some View {
            Button(store.state.actionName) {
                store.publish(())
            }
        }
    }
}

#endif
