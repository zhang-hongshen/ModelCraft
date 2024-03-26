//
//  ModelCraftTests.swift
//  ModelCraftTests
//
//  Created by 张鸿燊 on 22/3/2024.
//

import XCTest

final class ModelCraftTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: "2024-03-16T13:27:29.945803336+08:00") else {
            return
        }
        print("date \(date.formatted())")
    }
    
    // 测试获取环境变量PATH
    func testGetPath() {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        print("path: \(path)")
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }

}
