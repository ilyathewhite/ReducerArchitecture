//
//  ReducerArchitectureVC.swift
//  Rocket Insights
//
//  Created by Ilya Belenkiy on 03/30/21.
//  Copyright © 2021 Rocket Insights. All rights reserved.
//

#if canImport(UIKit)

import UIKit
import Combine
import CombineEx

public protocol BasicReducerArchitectureVC: UIViewController {
    associatedtype Store: AnyStore
    var store: Store { get }
    var value: AnyPublisher<Store.PublishedValue, Cancel> { get }
}

public extension BasicReducerArchitectureVC {
    typealias Value = Store.PublishedValue

    @MainActor
    var value: AnyPublisher<Store.PublishedValue, Cancel> {
        store.value
    }

    @MainActor
    func publish(_ value: Value) {
        store.publish(value)
    }

    @MainActor
    func cancel() {
        store.cancel()
    }
}

#endif

