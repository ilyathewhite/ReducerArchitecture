//
//  ReducerArchitectureTemplates.swift
//
//  Created by Ilya Belenkiy on 3/15/23.
//

import Foundation

/*
// Reducer
 
import ReducerArchitecture

enum <#StoreNsp#>: StoreNamespace {
    typealias PublishedValue = <#Value#>
    
    struct StoreEnvironment {
    }
    
    enum MutatingAction {
    }
    
    enum EffectAction {
    }
    
    struct StoreState {
    }
}

extension <#StoreNsp#> {
    static func reduce(_ state: inout StoreState, _ action: MutatingAction) -> Store.SyncEffect {
        switch action {
        }
    }

    static func runEffect(_ env: StoreEnvironment, _ state: StoreState, _ action: EffectAction) -> Store.Effect {
        switch action {
        }
    }
}
*/

/*
// StoreUI

import SwiftUI
import ReducerArchitecture

extension <#StoreNsp#>: StoreUINamespace {
    struct ContentView: StoreContentView {
        typealias Nsp = <#StoreNsp#>
        @ObservedObject var store: Store
        
        var body: some View {
            Text("hello")
        }
    }
}
 
struct <#Nsp#>_Previews: PreviewProvider {
    static let store = <#Nsp#>.store()
 
    static var previews: some View {
        store.contentView
    }
}
*/
