//
//  GenerativeUIParser.swift
//  ModelCraft
//
//  Created by Hongshen on 10/10/26.
//

import Foundation

/// A run of assistant content: leading model reasoning, Markdown text, or a `ui` block.
/// Segments are identified by their first line so they keep their identity while content streams.
enum MessageContentSegment: Identifiable {
    case thinking(text: String, isFinished: Bool)
    case markdown(id: Int, text: String)
    /// `source` is the block's SwiftUI code; `nil` while the block is still streaming.
    case ui(id: Int, source: String?)

    var id: Int {
        switch self {
        case .thinking: -1
        case .markdown(let id, _), .ui(let id, _): id
        }
    }

    /// Splits content at fenced blocks tagged `ui`. A block is shown once it is closed or
    /// the message is complete; code is not run while it streams. A `ui` fence inside
    /// another code block is ordinary code. Reasoning is the text between a leading
    /// `<think>` and `</think>`.
    static func segments(of content: String, isComplete: Bool) -> [MessageContentSegment] {
        var segments: [MessageContentSegment] = []
        var content = Substring(content)
        let leading = content.drop { $0.isWhitespace }
        if leading.hasPrefix("<think>") {
            let reasoning = leading.dropFirst("<think>".count)
            let end = reasoning.range(of: "</think>")
            let text = (end.map { reasoning[..<$0.lowerBound] } ?? reasoning)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(.thinking(text: text, isFinished: end != nil || isComplete))
            }
            content = end.map { reasoning[$0.upperBound...] } ?? ""
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        var markdown: [Substring] = []
        var markdownStart = 0
        var uiStart: Int?
        var uiLines: [Substring] = []
        var codeFence: String?

        func flushMarkdown() {
            let text = markdown.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(id: markdownStart, text: text))
            }
            markdown.removeAll()
        }

        func finishBlock(start: Int) {
            segments.append(.ui(id: start, source: uiLines.joined(separator: "\n")))
            uiLines.removeAll()
        }

        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let start = uiStart {
                if trimmed == "```" {
                    uiStart = nil
                    finishBlock(start: start)
                } else {
                    uiLines.append(line)
                }
                continue
            }
            if let fence = codeFence {
                if trimmed.hasPrefix(fence), trimmed.allSatisfy({ $0 == "`" }) {
                    codeFence = nil
                }
            } else if trimmed == "```ui" {
                flushMarkdown()
                uiStart = number
                continue
            } else if trimmed.hasPrefix("```") {
                codeFence = String(trimmed.prefix { $0 == "`" })
            }
            if markdown.isEmpty { markdownStart = number }
            markdown.append(line)
        }
        if let start = uiStart {
            if isComplete {
                finishBlock(start: start)
            } else {
                segments.append(.ui(id: start, source: nil))
            }
        }
        flushMarkdown()
        return segments
    }
}
