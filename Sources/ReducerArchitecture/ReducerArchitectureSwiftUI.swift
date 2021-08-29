//
//  File.swift
//  
//
//  Created by Ilya Belenkiy on 8/28/21.
//

#if canImport(SwiftUI)
import SwiftUI

public protocol StoreContentView: View {
    associatedtype StoreWrapper: StoreNamespace
    typealias Store = StoreWrapper.Store
    var store: Store { get }
    init(store: Store)
}

public protocol StoreUIWrapper {
    associatedtype ContentView: StoreContentView where ContentView.StoreWrapper == Self
}

public struct StoreUI<UIWrapper: StoreUIWrapper> {
    public let store: UIWrapper.Store

    public init(_ store: UIWrapper.Store) {
        self.store = store
    }

    public func makeView() -> UIWrapper.ContentView {
        UIWrapper.ContentView(store: store)
    }
    public var value: UIWrapper.Store.ValuePublisher { store.value }
}

#endif
