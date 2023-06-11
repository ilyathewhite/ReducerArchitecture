//
//  IntPickerUI.swift
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import SwiftUI
import ReducerArchitecture

extension IntPicker: StoreUINamespace {
    struct ContentView: StoreContentView {
        typealias Nsp = IntPicker
        @ObservedObject var store: Store
        
        func button(value: Int) -> some View {
            Button(action: { store.send(.mutating(.updateValue(value))) }) {
                let opacity = (value == store.state.value) ? 1 : 0.2
                Text(String(value))
                    .padding()
                    .border(Color.accentColor.opacity(opacity))
            }
        }
        
        var body: some View {
            VStack(spacing: 50) {
                HStack(spacing: 30) {
                    button(value: 1)
                    button(value: 2)
                    button(value: 3)
                }
                
                Button("Done!") {
                    if let value = store.state.value {
                        store.publish(value)
                    }
                }
                .disabled(store.state.value == nil)
            }
            .navigationTitle("Pick a number")
            .padding()
        }
    }
}

@available(iOS 16.0, *)
struct IntPicker_Previews: PreviewProvider {
    static let store = IntPicker.store()
    
    static var previews: some View {
        NavigationStack {
            store.contentView
        }
    }
}
