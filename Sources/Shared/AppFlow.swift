//
//  AppFlow.swift
//  TestsApp
//
//  Created by Ilya Belenkiy on 4/29/23.
//

import ReducerArchitecture

@MainActor
struct AppFlow {
    let flow: String
    let proxy: NavigationProxy

    func pickString(title: String?) -> NavigationNode<StringPicker> {
        .init(StringPicker.store(title: title), proxy)
    }

    func pickInt() -> NavigationNode<IntPicker> {
        .init(IntPicker.store(), proxy)
    }

    func pickDelimiter() -> NavigationNode<DelimiterPicker> {
        .init(DelimiterPicker.store(), proxy)
    }
    
    func finish(result: String) -> NavigationNode<Done> {
        .init(Done.store(value: result), proxy)
    }
    
    func pickStrings(result: [String], remainingCount: Int, callback: @escaping ([String]) async -> Void) async {
        if remainingCount == 0 {
            await callback(result)
        }
        else {
            await pickString(title: nil).then { string, _ in
                var result = result
                result.append(string)
                await pickStrings(result: result, remainingCount: remainingCount - 1, callback: callback)
            }
        }
    }
    
    func run() async {
        let rootIndex = proxy.currentIndex
        switch flow {
        case "Concatenate":
            await pickInt().then { count, _ in
                await pickDelimiter().then { delimiter, _ in
                    await pickStrings(result: [], remainingCount: count) { strings in
                        let result = strings.joined(separator: delimiter.rawValue)
                        await finish(result: result).then { _, _ in
                            proxy.popTo(rootIndex)
                        }
                    }
                }
            }
            
        case "Pair":
            await pickInt().then { intValue, _ in
                await pickString(title: nil).then { stringValue, _ in
                    await finish(result: "\(intValue), \(stringValue)").then { _, _ in
                        proxy.popTo(rootIndex)
                    }
                }
            }
            
        default:
            await finish(result: "Unknown Flow").then { _, _ in
                proxy.popTo(rootIndex)
            }
        }
    }
}
