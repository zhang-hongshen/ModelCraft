//
//  TagStreamParser.swift
//  ModelCraft
//
//  Created by You on 2025-08-18.
//

import Foundation

// MARK: - Parser state
public enum ParseState: Equatable {
    case outside
    case inThink
    case inAnswer
}

// MARK: - Events
public enum ParseEvent: Equatable {
    case state(ParseState)          // State transition (optional)
    case think(String)          // Text inside <think>...</think> (may not exist)
    case answer(String)         // Text inside <answer>...</answer>
}

// MARK: - Streaming tag parser
/// A streaming parser for three tags: <think>, <answer>.
/// - <think>...</think> is optional
/// - <answer>...</answer> is required
///
/// Key rules:
/// - Text outside tags is ignored.
/// - Text inside <think> or <answer> is emitted immediately as events.
/// - Tags may appear in any order.
/// - `safeTail` ensures incomplete tags split across chunks are not lost.
public final class TagStreamParser {
    // MARK: Config
    private let emitStates: Bool
    private let bufferLimit: Int
    private let safeTail: Int
    private let regex: NSRegularExpression

    // MARK: Runtime state
    private(set) public var state: ParseState = .outside
    private var buffer: String = ""
    private var followUpsRaw: String = ""

    // MARK: Init
    /// - Parameters:
    ///   - emitStates: Whether to emit `.state(...)` events on state transitions
    ///   - bufferLimit: Maximum buffer size before forced flush
    ///   - safeTail: Number of characters to preserve at buffer tail to handle split tags
    public init(emitStates: Bool = true,
                bufferLimit: Int = 1_000_000,
                safeTail: Int = 32) {
        self.emitStates = emitStates
        self.bufferLimit = bufferLimit
        self.safeTail = max(0, safeTail)

        // Matches opening/closing tags for think, answer, follow_ups
        self.regex = try! NSRegularExpression(
            pattern: #"<\s*(/?)\s*(think|answer|follow_ups)\s*>"#,
            options: [.caseInsensitive]
        )
    }

    // MARK: Feed
    /// Feed an incoming chunk of text into the parser.
    /// Returns parse events generated from this chunk.
    @discardableResult
    public func feed(_ chunk: String) -> [ParseEvent] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var events: [ParseEvent] = []
        var pos = buffer.startIndex

        @inline(__always)
        func setState(_ s: ParseState) {
            state = s
            if emitStates { events.append(.state(s)) }
        }

        while true {
            let searchRange = NSRange(pos..<buffer.endIndex, in: buffer)
            guard let m = regex.firstMatch(in: buffer, options: [], range: searchRange) else {
                // No more complete tags in buffer: emit safe prefix, keep tail
                let keep = max(0, buffer.count - safeTail)
                if let safeEnd = buffer.index(buffer.startIndex, offsetBy: keep, limitedBy: buffer.endIndex),
                   safeEnd > pos {
                    let text = String(buffer[pos..<safeEnd])
                    if !text.isEmpty {
                        events.append(contentsOf: emitText(text))
                    }
                    buffer.removeSubrange(buffer.startIndex..<safeEnd)
                } else {
                    buffer.removeSubrange(buffer.startIndex..<pos)
                }
                // Safety: flush buffer if it grows too large
                if buffer.count > bufferLimit {
                    events.append(contentsOf: emitText(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
                break
            }

            // Emit text before the tag
            if m.range.location > searchRange.location {
                let pre = NSRange(location: searchRange.location,
                                  length: m.range.location - searchRange.location)
                if let r = Range(pre, in: buffer) {
                    let text = String(buffer[r])
                    if !text.isEmpty {
                        events.append(contentsOf: emitText(text))
                    }
                }
            }

            // Parse the tag
            let whole = Range(m.range, in: buffer)!
            let isClose = (Range(m.range(at: 1), in: buffer).map { String(buffer[$0]) } ?? "").isEmpty == false
            let tagName = (Range(m.range(at: 2), in: buffer).map { String(buffer[$0]) } ?? "").lowercased()

            if !isClose {
                // Opening tag
                switch tagName {
                case "think": setState(.inThink)
                case "answer": setState(.inAnswer)
                default: break
                }
            } else {
                // Closing tag, only valid if state matches
                switch (tagName, state) {
                case ("think", .inThink):
                    setState(.outside)
                case ("answer", .inAnswer):
                    setState(.outside)
                default:
                    // Mismatched closing tag: ignored for robustness
                    break
                }
            }

            // Move scan position past this tag
            pos = whole.upperBound
        }

        return events
    }

    // MARK: - Helpers
    private func emitText(_ text: String) -> [ParseEvent] {
        guard !text.isEmpty else { return [] }
        switch state {
        case .outside:
            return [] // Ignore text outside tags
        case .inThink:
            return [.think(text)]
        case .inAnswer:
            return [.answer(text)]
        }
    }

}
