//
//  AppFlowTest.swift
//  
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import XCTest
import ReducerArchitecture
import UIKit
@testable import Shared

@MainActor
final class AppFlowTest: XCTestCase {
    // test for possible race conditions
    func testMany() async throws {
        for _ in 1...1000 {
            try await testPairFlow()
            try await testPairFlow2()
            try await testPairFlow3()
            try await testConcatenateFlow()
            try await testConcatenateFlow2()
        }
    }
    
    func testPairFlow() async throws {
        let env: NavigationEnv = .testEnv()
        
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = env.push(StoreUI(rootStore))
        
        let flow = AppFlow(flow: "Pair", env: env)
        
        let flowTask = Task {
            await flow.run()
        }
        
        var timeIndex = 1
        
        // int picker
        let intPickerStore = try await env.getStore(IntPicker.self, &timeIndex)
        await intPickerStore.publishOnRequest(2)
        
        // string picker
        let stringPickerStore = try await env.getStore(StringPicker.self, &timeIndex)
        stringPickerStore.send(.mutating(.updateValue("hello")))
        await stringPickerStore.publishOnRequest(stringPickerStore.state.value)

        // result
        let resultStore = try await env.getStore(Done.self, &timeIndex)
        
        // verify result
        XCTAssertEqual(resultStore.state.value, "2, hello")
        
        // end flow
        await resultStore.publishOnRequest(())

        // verify root
        let _ = try await env.getStore(StringPicker.self, &timeIndex)

        await flowTask.value
    }
    
    func testPairFlow2() async throws {
        let env: NavigationEnv = .testEnv()
        
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = env.push(StoreUI(rootStore))
        
        let flow = AppFlow(flow: "Pair", env: env)
        
        let flowTask = Task {
            await flow.run()
        }
        
        var timeIndex = 1
        
        // int picker
        let intPickerStore = try await env.getStore(IntPicker.self, &timeIndex)
        await intPickerStore.publishOnRequest(2)
        
        // string picker
        let stringPickerStore = try await env.getStore(StringPicker.self, &timeIndex)
        stringPickerStore.send(.mutating(.updateValue("hello")))
 
        // back to int picker
         env.backAction()
        
        let _intPickerStore = try await env.getStore(IntPicker.self, &timeIndex)
        XCTAssertEqual(_intPickerStore, intPickerStore)
        await intPickerStore.publishOnRequest(3)

        // string picker
        let stringPickerStore2 = try await env.getStore(StringPicker.self, &timeIndex)
        stringPickerStore2.send(.mutating(.updateValue("hi")))
        await stringPickerStore2.publishOnRequest(stringPickerStore2.state.value)

        // result
        let resultStore = try await env.getStore(Done.self, &timeIndex)
        
        // verify result
        XCTAssertEqual(resultStore.state.value, "3, hi")
        
        // end flow
        await resultStore.publishOnRequest(())
        
        // verify root
        let _ = try await env.getStore(StringPicker.self, &timeIndex)

        await flowTask.value
    }
    
    func testPairFlow3() async throws {
        let env: NavigationEnv = .testEnv()
        
        let rootStore = StringPicker.store(title: "Pick flow")
        _ = env.push(StoreUI(rootStore))
        
        let flow = AppFlow(flow: "Pair", env: env)
        
        let flowTask = Task {
            await flow.run()
        }
        
        var timeIndex = 1

        // int picker
        let intPickerStore = try await env.getStore(IntPicker.self, &timeIndex)
        intPickerStore.send(.mutating(.updateValue(1)))

        // back to start
        env.backAction()
        
        // verify root
        let _ = try await env.getStore(StringPicker.self, &timeIndex)

        await flowTask.value
    }
    
    func testConcatenateFlow() async throws {
        let env: NavigationEnv = .testEnv()

        let rootStore = StringPicker.store(title: "Pick flow")
        _ = env.push(StoreUI(rootStore))

        let flow = AppFlow(flow: "Concatenate", env: env)

        let flowTask = Task {
            await flow.run()
        }
        
        var timeIndex = 1

        // string count picker
        let stringCountStore = try await env.getStore(IntPicker.self, &timeIndex)
        await stringCountStore.publishOnRequest(3)
        
        // delimiter picker
        let delimiterPickerStore = try await env.getStore(DelimiterPicker.self, &timeIndex)
        await delimiterPickerStore.publishOnRequest(.pipe)
        
        // string picker 1
        let stringPicker1Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker1Store.send(.mutating(.updateValue("one")))
        await stringPicker1Store.publishOnRequest(stringPicker1Store.state.value)

        // string picker 2
        let stringPicker2Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker2Store.send(.mutating(.updateValue("two")))
        await stringPicker2Store.publishOnRequest(stringPicker2Store.state.value)

        // string picker 3
        let stringPicker3Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker3Store.send(.mutating(.updateValue("three")))
        await stringPicker3Store.publishOnRequest(stringPicker3Store.state.value)
        
        // result
        let resultStore = try await env.getStore(Done.self, &timeIndex)
        
        // verify result
        XCTAssertEqual(resultStore.state.value, "one|two|three")
        
        // end flow
        await resultStore.publishOnRequest(())

        // verify root
        let _ = try await env.getStore(StringPicker.self, &timeIndex)

        await flowTask.value
    }
    
    func testConcatenateFlow2() async throws {
        let env: NavigationEnv = .testEnv()

        let rootStore = StringPicker.store(title: "Pick flow")
        _ = env.push(StoreUI(rootStore))

        let flow = AppFlow(flow: "Concatenate", env: env)

        let flowTask = Task {
            await flow.run()
        }
        
        var timeIndex = 1

        // string count picker
        let stringCountStore = try await env.getStore(IntPicker.self, &timeIndex)
        await stringCountStore.publishOnRequest(3)
        
        // delimiter picker
        let delimiterPickerStore = try await env.getStore(DelimiterPicker.self, &timeIndex)
        await delimiterPickerStore.publishOnRequest(.pipe)
        
        // string picker 1
        let stringPicker1Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker1Store.send(.mutating(.updateValue("one")))
        
        // back to delimiter picker
        env.backAction()
        let _delimiterPickerStore = try await env.getStore(DelimiterPicker.self, &timeIndex)
        XCTAssertEqual(delimiterPickerStore, _delimiterPickerStore)
        await delimiterPickerStore.publishOnRequest(.dash)

        // string picker 2
        let stringPicker2Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker2Store.send(.mutating(.updateValue("two")))
        await stringPicker2Store.publishOnRequest(stringPicker2Store.state.value)

        // string picker 3
        let stringPicker3Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker3Store.send(.mutating(.updateValue("three")))
        
        // back to string picker 2
        env.backAction()
        let _stringPicker2Store = try await env.getStore(StringPicker.self, &timeIndex)
        XCTAssertEqual(stringPicker2Store, _stringPicker2Store)
        stringPicker2Store.send(.mutating(.updateValue("_three")))
        await stringPicker2Store.publishOnRequest(stringPicker2Store.state.value)
        
        // string picker 4
        let stringPicker4Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker4Store.send(.mutating(.updateValue("four")))
        await stringPicker4Store.publishOnRequest(stringPicker4Store.state.value)

        // string picker 5
        let stringPicker5Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker5Store.send(.mutating(.updateValue("five")))
        
        // back to string picker 4
        env.backAction()
        let _stringPicker4Store = try await env.getStore(StringPicker.self, &timeIndex)
        XCTAssertEqual(stringPicker4Store, _stringPicker4Store)
        stringPicker4Store.send(.mutating(.updateValue("four")))
        await stringPicker4Store.publishOnRequest(stringPicker4Store.state.value)

        // string picker 6
        let stringPicker6Store = try await env.getStore(StringPicker.self, &timeIndex)
        stringPicker6Store.send(.mutating(.updateValue("six")))
        await stringPicker6Store.publishOnRequest(stringPicker6Store.state.value)
        
        // result
        let _ = try await env.getStore(Done.self, &timeIndex)
        
        // back to string picker 6
        env.backAction()
        let _stringPicker6Store = try await env.getStore(StringPicker.self, &timeIndex)
        XCTAssertEqual(stringPicker6Store, _stringPicker6Store)
        stringPicker6Store.send(.mutating(.updateValue("_six")))
        await stringPicker6Store.publishOnRequest(stringPicker6Store.state.value)
        
        // result
        let resultStore2 = try await env.getStore(Done.self, &timeIndex)
        
        // verify result
        XCTAssertEqual(resultStore2.state.value, "_three-four-_six")
        
        // end flow
        await resultStore2.publishOnRequest(())

        // verify root
        let _ = try await env.getStore(StringPicker.self, &timeIndex)

        await flowTask.value
    }
}
