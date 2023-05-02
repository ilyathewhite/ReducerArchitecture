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

public class ContainerVC: UIViewController {
    let vc: any BasicReducerArchitectureVC
    
    init(vc: any BasicReducerArchitectureVC) {
        self.vc = vc
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        
        addChild(vc)
        view.addSubview(vc.view)
        vc.didMove(toParent: self)
        vc.view.align(toContainerView: view)
    }
    
    override public func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil {
            vc.store.cancel()
        }
    }
}

public protocol HostingControllerProtocol: UIViewController {
    associatedtype T: StoreUINamespace
    var store: T.Store { get }
}

public class HostingController<T: StoreUINamespace>: UIHostingController<T.ContentView>, HostingControllerProtocol {
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

extension UIView {
    func align(toContainerView view: UIView) {
        translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: rightAnchor).isActive = true
        view.topAnchor.constraint(equalTo: topAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
    }
}

#endif

