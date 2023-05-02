//
//  StringPickerUI.swift
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import SwiftUI
import ReducerArchitecture

extension StringPicker: StoreUINamespace {
    struct ContentView: StoreContentView {
        typealias Nsp = StringPicker
        @ObservedObject var store: Store
        
        var body: some View {
            VStack(spacing: 50) {
                TextField("Pick a string", text: store.binding(\.value, { .updateValue($0) }))
                    .autocorrectionDisabled()
                    .padding()
                    .border(Color.black.opacity(0.1))
                Button("Done!") {
                    store.publish(store.state.value)
                }
                .disabled(store.state.value.isEmpty)
            }
            .navigationTitle(store.state.title)
            .padding()
        }
    }
}

@available(iOS 16.0, *)
struct StringPicker_Previews: PreviewProvider {
    static let store = StringPicker.store()
    
    static var previews: some View {
        NavigationStack {
            StringPicker.ContentView(store: store)
        }
    }
}
