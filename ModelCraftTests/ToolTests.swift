//
//  ToolTests.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 25/1/26.
//


import XCTest
@testable import ModelCraft

final class ToolTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testComposeEmail() {
        AppTool.composeEmail(recipients: ["123@qq.com"], subject: "subject", body: "body")
    }
    
    func testMapSearch() async throws {
        let places = try await SearchTool.searchMap(query: "resturant", useCurrentLocation: true)
    }
    
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }
    
}
