//
//  DoneUI.swift
//  TestsApp
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import SwiftUI
import ReducerArchitecture

extension Done: StoreUINamespace {
    struct ContentView: StoreContentView {
        typealias Nsp = Done
        @ObservedObject var store: Store

        init(_ store: Store) {
            self.store = store
        }

        var body: some View {
            VStack(spacing: 50) {
                Text(store.state.value)
                    .font(.title)
                Button("Done!") {
                    store.publish(())
                }
            }
        }
    }
}

struct Done_Previews: PreviewProvider {
    static let store = Done.store(value: "abc")
    
    static var previews: some View {
        store.contentView
    }
}
