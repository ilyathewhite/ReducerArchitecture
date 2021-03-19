//
//  File.swift
//  
//
//  Created by Ilya Belenkiy on 3/18/21.
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
