//
//  ReducerArchitectureVC.swift
//  Rocket Insights
//
//  Created by Ilya Belenkiy on 03/30/21.
//  Copyright © 2021 Rocket Insights. All rights reserved.
//

#if canImport(UIKit)
import UIKit
#else
public class UIViewController {}
#endif

import SwiftUI
import Combine
import CombineEx

#if canImport(UIKit)

public class HostingController<T: StoreUINamespace>: UIHostingController<T.ContentView> {
    public let store: T.Store
    
    public init(store: T.Store) {
        self.store = store
        super.init(rootView: store.contentView)
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
