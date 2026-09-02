//
//  TagStreamParserTests.swift
//  ModelCraft
//
//  Created by Hongshen on 18/8/25.
//


import Testing
import AppKit
import SwiftUI
@testable import ModelCraft
import MLXLMCommon
import Tokenizers

final class TagStreamParserTests {

    @Test func chatMessageMarkdownUsesSwiftUIBodySize() {
        let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        let config = ChatMessageMarkdownStyle.config

        #expect(config.paragraphStyle.textFonts.normal.pointSize == bodySize)
        #expect(config.orderedListStyle.textFonts.normal.pointSize == bodySize)
        #expect(config.inlineStyle.linkTextFont.pointSize == bodySize)
        #expect(config.inlineStyle.codeTextFont.pointSize == bodySize)
    }

    @Test func codeBlocksUseAdaptiveGitHubTheme() {
        let config = ChatMessageMarkdownStyle.config.codeBlockConfig

        #expect(config.theme == .github)
        #expect(config.backgroundColor == Color(nsColor: .controlBackgroundColor))
        #expect(config.foregroundColor == Color(nsColor: .secondaryLabelColor))
    }

    @Test func assistantMarkdownKeepsModelTagsVisible() {
        let output = "<think>A & B</think><answer>Done</answer>"

        #expect(output.markdownEscapingHTML == "&lt;think&gt;A &amp; B&lt;/think&gt;&lt;answer&gt;Done&lt;/answer&gt;")
    }

    @Test func assistantMessagesAfterOneUserArePresentedAsOneTurn() {
        let firstUser = ModelCraft.Message(role: .user, content: "Please inspect this")
        let prelude = ModelCraft.Message(role: .assistant, content: "I will inspect it.")
        let toolCall = Self.toolMessage(ToolNames.readFromFile)
        let finalAnswer = ModelCraft.Message(role: .assistant, content: "It is ready.")
        let secondUser = ModelCraft.Message(role: .user, content: "Thanks")
        let secondAnswer = ModelCraft.Message(role: .assistant, content: "You're welcome.")

        let items = ConversationContentBuilder.items(from: [
            firstUser, prelude, toolCall, finalAnswer, secondUser, secondAnswer
        ])

        #expect(items.count == 4)
        guard case .assistantTurn(let firstTurn) = items[1] else {
            Issue.record("Expected assistant and tool messages after one user to form one turn")
            return
        }
        #expect(firstTurn.messages.map(\.id) == [prelude.id, toolCall.id, finalAnswer.id])
        #expect(firstTurn.userMessage?.id == firstUser.id)
        #expect(firstTurn.content == "I will inspect it.\n\nIt is ready.")

        guard case .assistantTurn(let secondTurn) = items[3] else {
            Issue.record("Expected the next user message to start a new assistant turn")
            return
        }
        #expect(secondTurn.messages.map(\.id) == [secondAnswer.id])
        #expect(secondTurn.userMessage?.id == secondUser.id)
    }

    @Test func persistedToolMessagesStayInsideTheAssistantTurn() {
        let user = ModelCraft.Message(role: .user, content: "Inspect this")
        let tool = ModelCraft.Message(
            role: .tool,
            content: "tool result",
            toolCall: ToolCall(function: .init(
                name: ToolNames.readFromFile,
                arguments: ["path": "Sources/App.swift"]
            )),
            toolCallResult: .success()
        )
        let answer = ModelCraft.Message(role: .assistant, content: "Done")

        let items = ConversationContentBuilder.items(from: [user, tool, answer])

        #expect(items.count == 2)
        guard case .assistantTurn(let turn) = items[1] else {
            Issue.record("Expected the persisted tool message to remain inside the assistant turn")
            return
        }
        #expect(turn.messages.map(\.id) == [tool.id, answer.id])
        #expect(turn.content == "Done")
    }

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

    @Test func assistantTextBetweenToolMessagesBreaksTheToolGroup() {
        let firstTool = Self.toolMessage(ToolNames.readFromFile)
        let assistantText = ModelCraft.Message(
            role: .assistant,
            content: "I will update the file next.",
            toolCall: ToolCall(function: .init(
                name: ToolNames.writeToFile,
                arguments: [:]
            )),
            toolCallResult: .success()
        )
        let lastTool = Self.toolMessage(ToolNames.executeCommand)

        let items = ChatContentBuilder.items(from: [
            firstTool, assistantText, lastTool
        ])

        #expect(items.count == 3)
        #expect(items.allSatisfy {
            if case .message = $0 { return true }
            return false
        })
    }

    @Test @MainActor
    func toolExecutionPersistsASeparateToolMessage() async throws {
        let model = LocalModel(id: "test-tool-storage", size: 0)
        let chat = Chat()
        let toolCall = ToolCall(
            function: .init(name: "test_tool", arguments: [:]))
        let toolResult = CallToolResult.success(
            content: [.text(TextContent(text: "visible result"))])
        var invocationCount = 0

        let executor = AgentExecutor(
            generationProvider: { _, _, _ in
                invocationCount += 1
                let (stream, continuation) = AsyncStream<Generation>.makeStream()
                if invocationCount == 1 {
                    continuation.yield(.chunk("Before the tool."))
                    continuation.yield(.toolCall(toolCall))
                } else {
                    continuation.yield(.chunk("After the tool."))
                }
                continuation.finish()
                return stream
            },
            toolDispatcher: { _ in
                (toolResult, MLXLMCommon.Chat.Message.tool("tool output"))
            })

        try await executor.run(
            model: model,
            projectID: nil,
            chat: chat,
            messages: [.user("run the tool")])

        let messages = chat.sortedMessages
        #expect(messages.count == 3)
        guard messages.count == 3 else { return }
        guard case .assistant = messages[0].role else {
            Issue.record("Expected the text before the tool to remain an assistant message")
            return
        }
        guard case .tool = messages[1].role else {
            Issue.record("Expected the tool execution to be persisted as a tool message")
            return
        }
        guard case .assistant = messages[2].role else {
            Issue.record("Expected the text after the tool to remain an assistant message")
            return
        }
        #expect(messages.map(\.content) == [
            "Before the tool.", "tool output", "After the tool."
        ])
        #expect(messages[0].toolCall == nil)
        #expect(messages[0].toolCallResult == nil)
        #expect(messages[1].toolCall?.function.name == "test_tool")
        #expect(messages[1].toolCallResult?.isError == false)
    }

    @Test @MainActor
    func assistantIsGeneratingBeforeTheFirstTokenArrives() async throws {
        let model = LocalModel(id: "test-initial-generation-status", size: 0)
        let chat = Chat()
        var streamContinuation: AsyncStream<Generation>.Continuation?

        let executor = AgentExecutor(
            generationProvider: { _, _, _ in
                let (stream, continuation) = AsyncStream<Generation>.makeStream()
                streamContinuation = continuation
                return stream
            },
            toolDispatcher: { _ in
                Issue.record("No tool should be dispatched")
                return (.success(), .tool(""))
            })

        let generationTask = Task {
            try await executor.run(
                model: model,
                projectID: nil,
                chat: chat,
                messages: [.user("hello")])
        }

        while streamContinuation == nil {
            await Task.yield()
        }

        #expect(chat.sortedMessages.last?.status == .generating)
        #expect(chat.isGenerating)

        streamContinuation?.finish()
        try await generationTask.value
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

    @Test func compactCommandDescriptionDoesNotExposeTheCommand() {
        let command = "swift test --filter ToolPresentation"
        let toolCall = ToolCall(function: .init(
            name: ToolNames.executeCommand,
            arguments: ["command": "swift test --filter ToolPresentation"]
        ))

        let descriptions = [
            toolCall.compactDescription(.running),
            toolCall.compactDescription(.completed),
            toolCall.compactDescription(.failed)
        ]

        #expect(descriptions.allSatisfy { !$0.contains(command) })
        #expect(Set(descriptions).count == 3)
    }

    @Test func fileDisplayNameUsesOnlyTheLastPathComponent() {
        let toolCall = ToolCall(function: .init(
            name: ToolNames.writeToFile,
            arguments: ["path": "/Users/example/Project/Sources/App.swift"]
        ))

        #expect(toolCall.fileDisplayName == "App.swift")
    }

#if os(macOS)
    @Test @MainActor func commandExecutionDoesNotBlockMainActor() async throws {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let command = Task { @MainActor in
            try await CommandTool.executeCommand("sleep 0.4")
        }

        await Task.yield()
        try await Task.sleep(for: .milliseconds(50))

        #expect(startedAt.duration(to: clock.now) < .milliseconds(250))
        _ = try await command.value
    }
#endif

    private static func toolMessage(_ name: String) -> ModelCraft.Message {
        ModelCraft.Message(
            role: .tool,
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
