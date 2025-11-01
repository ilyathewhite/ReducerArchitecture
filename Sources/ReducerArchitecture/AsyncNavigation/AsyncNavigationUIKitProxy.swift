//
//  AsyncNavigationUIKitProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 10/31/25.
//

import SwiftUI

#if canImport(UIKit)
import UIKit

class AsyncNavigationUIKitProxy: AsyncNavigationProxy {
    public class HostingController<T: ViewModelUINamespace>: UIHostingController<T.ContentView> {
        public let viewModel: T.ViewModel

        public init(_ viewModelUI: ViewModelUI<T>) {
            self.viewModel = viewModelUI.viewModel
            super.init(rootView: viewModelUI.makeView())
        }

        @MainActor required dynamic init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        public override func didMove(toParent parent: UIViewController?) {
            if parent == nil {
                viewModel.cancel()
            }
        }
    }

    private var nc: UINavigationController

    public init(_ nc: UINavigationController) {
        self.nc = nc
    }

    var currentIndex: Int {
        nc.viewControllers.count - 1
    }

    func push<T: ViewModelUINamespace>(_ viewModelUI: ViewModelUI<T>) -> Int {
        let vc = HostingController(viewModelUI)
        nc.pushViewController(vc, animated: true)
        return nc.viewControllers.count - 1
    }
    
    func replaceTop<T: ViewModelUINamespace>(with viewModelUI: ViewModelUI<T>) -> Int {
        guard !nc.viewControllers.isEmpty else { return -1 }
        let vc = HostingController(viewModelUI)
        nc.viewControllers[nc.viewControllers.count - 1] = vc
        return nc.viewControllers.count - 1
    }

    func popTo(_ index: Int) {
        let vc = nc.viewControllers[index]
        nc.popToViewController(vc, animated: true)
    }
}

#endif
