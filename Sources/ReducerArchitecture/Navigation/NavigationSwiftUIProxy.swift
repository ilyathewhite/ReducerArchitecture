//
//  NavigationSwiftUIProxy.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

extension NavigationEnv {
    @MainActor
    public init(pathContainer: NavigationPathContainer) {
        self.init(
            currentIndex: {
                pathContainer.currentIndex
            },
            push: {
                pathContainer.push($0)
            },
            replaceTop: {
                pathContainer.replaceTop(newValue: $0)
            },
            popTo: {
                pathContainer.popTo(index: $0)
            }
        )
    }
}
