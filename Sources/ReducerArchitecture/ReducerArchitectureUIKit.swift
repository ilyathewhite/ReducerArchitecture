//
//  ReducerArchitectureVC.swift
//  Rocket Insights
//
//  Created by Ilya Belenkiy on 03/30/21.
//  Copyright © 2021 Rocket Insights. All rights reserved.
//

#if canImport(UIKit)

import UIKit
import SwiftUI
import Combine
import CombineEx

public protocol BasicReducerArchitectureVC: UIViewController {
    associatedtype Store: AnyStore
    associatedtype Configuration

    var store: Store { get }
    static func make(_ configuration: Configuration) -> Self
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

public class HostingController<T: StoreUINamespace>: UIHostingController<T.ContentView> {
    public let store: T.Store
    
    public init(store: T.Store) {
        self.store = store
        super.init(rootView: T.ContentView(store: store))
    }
    
    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func didMove(toParent parent: UIViewController?) {
        if parent == nil {
            store.cancel()
        }
    }
}

#endif

