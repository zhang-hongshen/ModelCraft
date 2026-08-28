//
//  ComputerUseToolTests.swift
//  ModelCraftTests
//
//  Created by Hongshen on 13/6/26.
//

import Testing
@testable import ModelCraft
import Foundation

struct ComputerUseToolTests {

    @Test func testListRunningApplication() async throws {
        let input = ListRunningApplicationInput()
        let output = try await ComputerUseTool.listRunningApplication.handler(input)
        print(output)
    }
    
    @Test func testGetUIHierarchy() async throws {
        let input = GetUIHierarchyInput(appID: "com.apple.Safari", appName: nil, maxDepth: nil)
        let output = try await ComputerUseTool.getUIHierarchy.handler(input)
        printPrettifiedly(output)
    }
    
    @Test func testTypeText() async throws {
        let input = TypeTextInput(appID: "com.apple.Safari", appName: nil, index: 1, text: "ModelCraft")
        let output = try await ComputerUseTool.typeText.handler(input)
    }
    
    @Test func testClickElement() async throws {
        let input = ClickElementInput(appID: "com.apple.Safari", appName: nil, index: 1, action: "AXRaise")
        let output = try await ComputerUseTool.clickElement.handler(input)
    }
    
    func printPrettifiedly<T: Encodable>(_ data: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        do {
            let data = try encoder.encode(data)
            print(String(data: data, encoding: .utf8) ?? "")
        } catch {
            print(error.localizedDescription)
        }
        
    }

}
