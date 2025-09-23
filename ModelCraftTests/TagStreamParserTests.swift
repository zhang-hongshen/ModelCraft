//
//  TagStreamParserTests.swift
//  ModelCraft
//
//  Created by Hongshen on 18/8/25.
//


import XCTest
@testable import ModelCraft

final class TagStreamParserTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }
    
    func testFullInputSingleChunk() {
            let parser = TagStreamParser()

            let input = """
            <think>reasoning</think><answer>final answer</answer>
            """
            let events = parser.feed(input)

            var think = ""
            var answer = ""

            for e in events {
                switch e {
                case .think(let t): think += t
                case .answer(let t): answer += t
                default: break
                }
            }

            XCTAssertEqual(think, "reasoning")
            XCTAssertEqual(answer, "final answer")
        }

        func testSplitChunks() {
            let parser = TagStreamParser()

            let chunks = [
                "<thi", "nk>res", "on", "ing</thi", "nk>",
                "<answ", "er>hel", "lo</ans", "wer>"
            ]

            var think = ""
            var answer = ""

            for ch in chunks {
                let events = parser.feed(ch)
                for e in events {
                    switch e {
                    case .think(let t): think += t
                    case .answer(let t): answer += t
                    default: break
                    }
                }
            }

            XCTAssertEqual(think, "resoning") // 拼接结果
            XCTAssertEqual(answer, "hello")
        }
    }
