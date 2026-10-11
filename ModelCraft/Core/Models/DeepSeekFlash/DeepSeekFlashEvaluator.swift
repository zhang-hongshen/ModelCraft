//
//  DeepSeekFlashEvaluator.swift
//  ModelCraft
//
//  Created by Hongshen on 27/9/26.
//

import Foundation
import MLXLMCommon
import Tokenizers

final class DeepSeekFlashEvaluator {
    static let repositoryID = DeepSeekFlashConfiguration.repositoryID

    private static let toolCallsStart = "<｜DSML｜tool_calls>"
    private static let toolCallsEnd = "</｜DSML｜tool_calls>"

    private let modelFactory = DeepSeekFlashModelFactory()

    func tokenCount(
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec] = []
    ) async throws -> Int {
        let input = try render(messages: messages, tools: tools)
        return try await modelFactory.tokenCount(
            prompt: input.prompt,
            images: input.images)
    }

    func generate(
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec] = [],
        maximumSequenceLength: Int,
        maximumNewTokens: Int? = nil,
        temperature: Float = 1
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        let input = try render(messages: messages, tools: tools)
        let model = try await modelFactory.load(
            maximumSequenceLength: maximumSequenceLength)
        let stream = model.generate(
            prompt: input.prompt,
            images: input.images,
            maximumNewTokens: maximumNewTokens,
            temperature: temperature)

        return AsyncThrowingStream { continuation in
            let task = Task {
                var pendingText = ""
                var toolText = ""
                var readingToolCall = false

                func emit(_ chunk: String) {
                    guard !chunk.isEmpty else { return }
                    if readingToolCall {
                        toolText += chunk
                        return
                    }

                    pendingText += chunk
                    if let markerRange = pendingText.range(of: Self.toolCallsStart) {
                        let text = String(pendingText[..<markerRange.lowerBound])
                        if !text.isEmpty {
                            continuation.yield(.chunk(text))
                        }
                        toolText = String(pendingText[markerRange.lowerBound...])
                        pendingText.removeAll(keepingCapacity: true)
                        readingToolCall = true
                        return
                    }

                    let retainedCount = min(Self.toolCallsStart.count - 1, pendingText.count)
                    let readyEnd = pendingText.index(
                        pendingText.endIndex,
                        offsetBy: -retainedCount)
                    let ready = String(pendingText[..<readyEnd])
                    if !ready.isEmpty {
                        continuation.yield(.chunk(ready))
                        pendingText = String(pendingText[readyEnd...])
                    }
                }

                func emitBufferedOutput() {
                    if readingToolCall {
                        let parsed = Self.parseToolCalls(toolText)
                        if parsed.calls.isEmpty {
                            continuation.yield(.chunk(toolText))
                        } else {
                            if !parsed.content.isEmpty {
                                continuation.yield(.chunk(parsed.content))
                            }
                            for call in parsed.calls {
                                continuation.yield(.toolCall(call))
                            }
                        }
                    } else if !pendingText.isEmpty {
                        continuation.yield(.chunk(pendingText))
                    }
                }

                do {
                    for try await generation in stream {
                        switch generation {
                        case .chunk(let chunk):
                            emit(chunk)
                        case .info(let info):
                            emitBufferedOutput()
                            continuation.yield(.info(.init(
                                promptTokenCount: info.promptTokenCount,
                                generationTokenCount: info.generationTokenCount,
                                promptTime: info.promptTime,
                                generationTime: info.generationTime,
                                stopReason: info.reachedTokenLimit ? .length : .stop)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func render(
        messages: [MLXLMCommon.Chat.Message],
        tools: [ToolSpec]
    ) throws -> (prompt: String, images: [UserInput.Image]) {
        var prompt = "<｜begin▁of▁sentence｜>"
        var toolsWritten = false
        var images = [UserInput.Image]()

        for message in messages {
            guard message.videos.isEmpty else {
                throw DeepSeekFlashImageProcessorError.unsupportedVideo
            }
            let content = ([String](
                repeating: DeepSeekFlashTokenizer.imagePlaceholder,
                count: message.images.count) + [message.content])
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            images.append(contentsOf: message.images)
            switch message.role {
            case .system:
                prompt += content
                if !tools.isEmpty, !toolsWritten {
                    prompt += renderTools(tools)
                    toolsWritten = true
                }
            case .user:
                if !tools.isEmpty, !toolsWritten {
                    prompt += renderTools(tools)
                    toolsWritten = true
                }
                prompt += "<｜User｜>" + content
            case .assistant:
                prompt += "<｜Assistant｜></think>"
                prompt += content + renderToolCalls(of: message) + "<｜end▁of▁sentence｜>"
            case .tool:
                prompt += "<｜User｜><tool_result>"
                prompt += content
                prompt += "</tool_result>"
            }
        }

        if !tools.isEmpty, !toolsWritten {
            prompt += renderTools(tools)
        }
        prompt += "<｜Assistant｜></think>"
        return (prompt, images)
    }

    /// Renders an assistant message's tool calls in the DSML format the model emits, so the
    /// following tool result is paired with the call that produced it.
    private func renderToolCalls(of message: MLXLMCommon.Chat.Message) -> String {
        var metadata: [String: any Sendable] = [:]
        DefaultMessageGenerator().addToolMetadata(to: &metadata, for: message)
        guard let calls = metadata["tool_calls"] as? [[String: any Sendable]],
              !calls.isEmpty
        else {
            return ""
        }

        let invocations = calls.compactMap { call -> String? in
            guard let function = call["function"] as? [String: any Sendable],
                  let name = function["name"] as? String
            else {
                return nil
            }
            let arguments = function["arguments"] as? [String: any Sendable] ?? [:]
            let parameters = arguments.keys.sorted().map { key in
                let value = arguments[key]
                if let string = value as? String {
                    return "<｜DSML｜parameter name=\"\(key)\" string=\"true\">\(string)</｜DSML｜parameter>"
                }
                // Invalid objects raise instead of throwing, so validate inside an array first.
                let json = value
                    .flatMap { JSONSerialization.isValidJSONObject([$0]) ? $0 : nil }
                    .flatMap { try? JSONSerialization.data(
                        withJSONObject: $0,
                        options: [.fragmentsAllowed, .sortedKeys]) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? "null"
                return "<｜DSML｜parameter name=\"\(key)\" string=\"false\">\(json)</｜DSML｜parameter>"
            }
            return (["<｜DSML｜invoke name=\"\(name)\">"] + parameters + ["</｜DSML｜invoke>"])
                .joined(separator: "\n")
        }
        return "\n\n" + ([Self.toolCallsStart] + invocations + [Self.toolCallsEnd])
            .joined(separator: "\n")
    }

    private func renderTools(_ tools: [ToolSpec]) -> String {
        let schemas = tools.compactMap { tool -> String? in
            guard JSONSerialization.isValidJSONObject(tool),
                  let data = try? JSONSerialization.data(
                    withJSONObject: tool,
                    options: [.sortedKeys]),
                  let value = String(data: data, encoding: .utf8)
            else {
                return nil
            }
            return value
        }.joined(separator: "\n")

        return """

        You have access to the following tools:
        <tools>
        \(schemas)
        </tools>
        For each function call, return the call using this exact format:
        <｜DSML｜tool_calls>
        <｜DSML｜invoke name="function_name">
        <｜DSML｜parameter name="parameter_name" string="true">parameter_value</｜DSML｜parameter>
        </｜DSML｜invoke>
        </｜DSML｜tool_calls>
        """
    }

    private static func parseToolCalls(
        _ text: String
    ) -> (content: String, calls: [ToolCall]) {
        guard let start = text.range(of: toolCallsStart),
              let end = text.range(
                of: toolCallsEnd,
                range: start.upperBound ..< text.endIndex)
        else {
            return (text, [])
        }

        let body = String(text[start.upperBound ..< end.lowerBound])
        let invokePattern = #"<｜DSML｜invoke name="([^"]+)">([\s\S]*?)</｜DSML｜invoke>"#
        let parameterPattern = #"<｜DSML｜parameter name="([^"]+)" string="(true|false)">([\s\S]*?)</｜DSML｜parameter>"#
        guard let invokeExpression = try? NSRegularExpression(pattern: invokePattern),
              let parameterExpression = try? NSRegularExpression(pattern: parameterPattern)
        else {
            return (text, [])
        }

        let invokeRange = NSRange(body.startIndex ..< body.endIndex, in: body)
        let calls = invokeExpression
            .matches(in: body, range: invokeRange)
            .compactMap { match -> ToolCall? in
                guard let nameRange = Range(match.range(at: 1), in: body),
                      let parametersRange = Range(match.range(at: 2), in: body)
                else {
                    return nil
                }

                let name = String(body[nameRange])
                let parameters = String(body[parametersRange])
                let range = NSRange(parameters.startIndex ..< parameters.endIndex, in: parameters)
                var arguments = [String: any Sendable]()
                for parameter in parameterExpression.matches(in: parameters, range: range) {
                    guard let parameterNameRange = Range(parameter.range(at: 1), in: parameters),
                          let stringRange = Range(parameter.range(at: 2), in: parameters),
                          let valueRange = Range(parameter.range(at: 3), in: parameters)
                    else {
                        continue
                    }

                    let parameterName = String(parameters[parameterNameRange])
                    let value = String(parameters[valueRange])
                    if parameters[stringRange] == "true" {
                        arguments[parameterName] = value
                    } else if let data = value.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(
                                with: data,
                                options: .fragmentsAllowed),
                              let sendable = sendableJSONValue(object)
                    {
                        arguments[parameterName] = sendable
                    } else {
                        arguments[parameterName] = value
                    }
                }
                return ToolCall(function: .init(name: name, arguments: arguments))
            }

        guard !calls.isEmpty else { return (text, []) }
        var content = String(text[..<start.lowerBound])
        if content.hasSuffix("\n\n") {
            content.removeLast(2)
        }
        return (content, calls)
    }

    private static func sendableJSONValue(_ value: Any) -> (any Sendable)? {
        switch value {
        case let value as String:
            value
        case let value as Bool:
            value
        case let value as Int:
            value
        case let value as Double:
            value
        case let value as NSNumber:
            value.doubleValue
        case let values as [Any]:
            values.compactMap(sendableJSONValue)
        case let values as [String: Any]:
            values.compactMapValues(sendableJSONValue)
        default:
            nil
        }
    }
}
