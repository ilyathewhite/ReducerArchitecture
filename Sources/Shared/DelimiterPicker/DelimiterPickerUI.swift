//
//  DelimiterPickerUI.swift
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import SwiftUI
import ReducerArchitecture

extension DelimiterPicker: StoreUINamespace {
    struct ContentView: StoreContentView {
        typealias Nsp = DelimiterPicker
        @ObservedObject var store: Store
        
        func button(value: Nsp.Delimiter) -> some View {
            Button(action: { store.send(.mutating(.updateValue(value))) }) {
                let opacity = (value == store.state.value) ? 1 : 0.2
                Text(value.rawValue)
                    .padding()
                    .border(Color.accentColor.opacity(opacity))
            }
        }
        
        var body: some View {
            VStack(spacing: 50) {
                HStack(spacing: 30) {
                    ForEach(Nsp.Delimiter.allCases) {
                        button(value: $0)
                    }
                }
                
                Button("Done!") {
                    if let value = store.state.value {
                        store.publish(value)
                    }
                }
                .disabled(store.state.value == nil)
            }
            .navigationTitle("Pick a delimiter")
            .padding()
        }
    }
}

@available(iOS 16.0, *)
struct DelimiterPicker_Previews: PreviewProvider {
    static let store = DelimiterPicker.store()
    
    static var previews: some View {
        NavigationStack {
            store.contentView
        }
    }
}
