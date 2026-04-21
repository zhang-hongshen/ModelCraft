//
//  ModelCraftTests.swift
//  ModelCraftTests
//
//  Created by Hongshen on 22/3/2024.
//

import XCTest
import PDFKit
@testable import ModelCraft

final class ModelCraftTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testReadAudioFile() async throws {
       let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "test", withExtension: "mp3") else {
           XCTFail("File not found")
           return
       }
        print("audio content: ", try await url.readContent())
    }
    
    
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }

}
