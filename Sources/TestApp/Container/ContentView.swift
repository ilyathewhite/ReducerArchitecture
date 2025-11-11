//
//  ContentView.swift
//  Container
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import SwiftUI
import ReducerArchitecture

struct ContentView: View {
    var body: some View {
        NavigationFlow(StringPicker.store(title: "Pick flow")) { flow, proxy in
            await AppFlow(flow: flow, proxy: proxy).run()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
