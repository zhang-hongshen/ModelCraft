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
            <thought>reasoning</thought><answer>final answer</answer>
            """
            let events = parser.feed(input)

            var thought = ""
            var answer = ""

            for event in events {
                switch event {
                case .tag(let name, let content):
                    switch name {
                    case "thought": thought.append(content)
                    case "answer": answer.append(content)
                    default: break
                    }
                default: break
                }
            }

            XCTAssertEqual(thought, "reasoning")
            XCTAssertEqual(answer, "final answer")
        }

        func testSplitChunks() {
            let parser = TagStreamParser()

            let chunks = [
                "<tho", "ught>res", "on", "ing</tho", "ught>",
                "<answ", "er>hel", "lo</ans", "wer>"
            ]

            var thought = ""
            var answer = ""

            for chunk in chunks {
                for event in parser.feed(chunk) {
                    switch event {
                    case .tag(let name, let content):
                        switch name {
                        case "thought": thought.append(content)
                        case "answer": answer.append(content)
                        default: break
                        }
                    default: break
                    }
                }
            }

            XCTAssertEqual(thought, "resoning")
            XCTAssertEqual(answer, "hello")
        }
    }
