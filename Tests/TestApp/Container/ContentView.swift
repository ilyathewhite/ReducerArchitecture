//
//  ContentView.swift
//  Container
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import SwiftUI
import ReducerArchitecture
import AsyncNavigation

struct ContentView: View {
    func rootPicker() -> RootNavigationNode<StringPicker> {
        .init(StringPicker.store(title: "Pick flow"))
    }

    var body: some View {
        NavigationFlow(rootPicker()) { flow, proxy in
            await AppFlow(flow: flow, proxy: proxy).run()
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
