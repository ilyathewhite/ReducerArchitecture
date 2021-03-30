//
//  Environment.swift
//  Rocket Insights
//
//  Created by Ilya Belenkiy on 03/30/21.
//  Copyright © 2021 Rocket Insights. All rights reserved.
//

import Foundation

public enum ReducerArchitecture {
    public struct Environment {
        public var appNamePrefix = ""
        public var log: (String) -> Void
    }

    public static var env = Environment(
        log: { NSLog($0) }
    )
}
