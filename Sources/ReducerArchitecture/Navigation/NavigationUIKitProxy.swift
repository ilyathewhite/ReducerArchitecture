//
//  NavigationUIKitProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

#if canImport(UIKit)
import UIKit

extension NavigationEnv {
    static func hostingVC(_ storeUI: some StoreUIContainer, _ container: @escaping () -> UIViewController?) -> UIViewController {
        let vc = HostingController(store: storeUI.store)

        if let appVC = container() {
            appVC.addChild(vc)
            appVC.view.addSubview(vc.view)
            vc.didMove(toParent: appVC)
            vc.view.align(toContainerView: appVC.view)
            return appVC
        }
        else {
            return vc
        }
    }

    @MainActor
    public init(
        _ nc: UINavigationController,
        replaceLastWith: @escaping (UINavigationController, UIViewController) -> Void,
        hostingControllerContainer: @escaping () -> UIViewController? = { nil }
    ) {
        self.init(
            currentIndex: {
                nc.viewControllers.count - 1
            },
            push: {
                let vc = Self.hostingVC($0, hostingControllerContainer)
                nc.pushViewController(vc, animated: true)
                return nc.viewControllers.count - 1
            },
            pushVC: {
                let vc = ContainerVC(vc: $0)
                nc.pushViewController(vc, animated: true)
                return nc.viewControllers.count - 1
            },
            replaceTop: {
                let vc = Self.hostingVC($0, hostingControllerContainer)
                replaceLastWith(nc, vc)
                return nc.viewControllers.count - 1
            },
            popTo: {
                let vc = nc.viewControllers[$0]
                nc.popToViewController(vc, animated: true)
            }
        )
    }
}

#endif
