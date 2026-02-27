//
//  MLXServiceTests.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import XCTest
@testable import ModelCraft

final class MLXServiceTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }
    
    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testFetchModels() async throws {
        let models = try await MLXService.shared.fetchModels()
        print(models)
    }
    
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }
    
}
