//
//  NavigationEnvKeys.swift
//  ReducerArchitecture
//
//  Created by Ilya Belenkiy on 11/4/25.
//

import SwiftUI

private struct BackActionKey: EnvironmentKey {
    static let defaultValue: (() -> ())? = nil
}

public extension EnvironmentValues {
    var backAction: (() -> ())? {
        get { self[BackActionKey.self] }
        set { self[BackActionKey.self] = newValue }
    }
}

public struct NavigationPathStack: Equatable {
    public let value: [any ViewModelUIContainer]

    @MainActor
    public static func ==(lhs: NavigationPathStack, rhs: NavigationPathStack) -> Bool {
        lhs.value.map { $0.id } == rhs.value.map { $0.id }
    }
}

public struct NavigationPathStackKey: PreferenceKey {
    public static let defaultValue: NavigationPathStack? = nil

    public static func reduce(value: inout NavigationPathStack?, nextValue: () -> NavigationPathStack?) {
        value = value ?? nextValue()
    }
}


