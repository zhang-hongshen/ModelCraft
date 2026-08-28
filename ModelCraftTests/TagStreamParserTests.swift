//
//  TagStreamParserTests.swift
//  ModelCraft
//
//  Created by Hongshen on 18/8/25.
//


import Testing
@testable import ModelCraft
import MLXLMCommon

final class TagStreamParserTests {

    @Test func toolCallsAreGroupedOnlyWhenTheyAreContiguousAndMultiple() {
        let messages = [
            Self.toolMessage(ToolNames.readFromFile),
            Self.toolMessage(ToolNames.writeToFile),
            ModelCraft.Message(role: .assistant, content: "The files are ready."),
            Self.toolMessage(ToolNames.executeCommand)
        ]

        let items = ChatContentBuilder.items(from: messages)

        #expect(items.count == 3)
        guard case .toolCallGroup(let firstGroup) = items[0] else {
            Issue.record("Expected the first two contiguous tool calls to be grouped")
            return
        }
        #expect(firstGroup.count == 2)
        guard case .message(let message) = items[1] else {
            Issue.record("Expected the normal assistant message to remain separate")
            return
        }
        #expect(message.content == "The files are ready.")
        guard case .message(let lastMessage) = items[2] else {
            Issue.record("Expected a single tool call to remain ungrouped")
            return
        }
        #expect(lastMessage.toolCall?.function.name == ToolNames.executeCommand)
    }

    @Test func imageGenerationRemainsOutsideToolCallGroups() {
        let messages = [
            Self.toolMessage(ToolNames.readFromFile),
            Self.toolMessage(ToolNames.textToImage),
            Self.toolMessage(ToolNames.executeCommand)
        ]

        let items = ChatContentBuilder.items(from: messages)

        #expect(items.count == 3)
        guard case .message(let imageMessage) = items[1] else {
            Issue.record("Image generation should be rendered as a standalone message")
            return
        }
        #expect(imageMessage.toolCall?.function.name == ToolNames.textToImage)
    }

    @Test func completedToolGroupSummaryUsesSpecificToolCounts() {
        let messages = [
            Self.toolMessage(ToolNames.readFromFile),
            Self.toolMessage(ToolNames.writeToFile),
            Self.toolMessage(ToolNames.executeCommand)
        ]

        let summary = ToolCallGroupSummary(messages: messages)

        #expect(summary.fileReadCount == 1)
        #expect(summary.fileWriteCount == 1)
        #expect(summary.commandCount == 1)
        #expect(summary.isRunning == false)
    }

    private static func toolMessage(_ name: String) -> ModelCraft.Message {
        ModelCraft.Message(
            role: .assistant,
            toolCall: ToolCall(function: .init(name: name, arguments: [:])),
            toolCallResult: .success()
        )
    }

    @Test func testFullInputSingleChunk() {
            let parser = TagStreamParser()

            let input = """
            <thought>reasoning</thought><answer>final answer</answer>
            """
            let events = parser.feed(input)

            var thought = ""
            var answer = ""

            for event in events {
                switch event {
                case .inTag(let name, let content):
                    switch name {
                    case "thought": thought.append(content)
                    case "answer": answer.append(content)
                    default: break
                    }
                default: break
                }
            }

        #expect(thought == "reasoning")
        #expect(answer == "final answer")
    }

    @Test func testSplitChunks() {
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
                    case .inTag(let name, let content):
                        switch name {
                        case "thought": thought.append(content)
                        case "answer": answer.append(content)
                        default: break
                        }
                    default: break
                    }
                }
            }

            #expect(thought == "reasoning")
            #expect(answer == "hello")
        }
    }
