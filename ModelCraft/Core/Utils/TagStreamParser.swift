//
//  TagStreamParser.swift
//  ModelCraft
//
//  Created by Hongshen on 18/8/2025.
//

import Foundation

public enum ParseState: Equatable {
    case outside
    case inTag(String)
}

public enum ParseEvent: Equatable {
    case outside
    case inTag(name: String, content: String)
}

public final class TagStreamParser {

    private let bufferLimit: Int
    private let safeTail: Int
    private let regex: NSRegularExpression

    private(set) public var state: ParseState = .outside
    private var buffer: String = ""

    public init(bufferLimit: Int = 1_000_000,
                safeTail: Int = 32) {
        self.bufferLimit = bufferLimit
        self.safeTail = max(0, safeTail)

        self.regex = try! NSRegularExpression(
            pattern: #"<\s*(/?)\s*([a-zA-Z0-9_]+)\s*>"#,
            options: [.caseInsensitive]
        )
    }

    @discardableResult
    public func feed(_ chunk: String) -> [ParseEvent] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var events: [ParseEvent] = []
        var pos = buffer.startIndex

        while true {
            let searchRange = NSRange(pos..<buffer.endIndex, in: buffer)
            guard let m = regex.firstMatch(in: buffer, options: [], range: searchRange) else {
                let keep = max(0, buffer.count - safeTail)
                if let safeEnd = buffer.index(buffer.startIndex, offsetBy: keep, limitedBy: buffer.endIndex),
                   safeEnd > pos {
                    let text = String(buffer[pos..<safeEnd])
                    events.append(contentsOf: emitText(text))
                    buffer.removeSubrange(buffer.startIndex..<safeEnd)
                } else {
                    buffer.removeSubrange(buffer.startIndex..<pos)
                }

                if buffer.count > bufferLimit {
                    events.append(contentsOf: emitText(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
                break
            }

            if m.range.location > searchRange.location {
                let pre = NSRange(
                    location: searchRange.location,
                    length: m.range.location - searchRange.location
                )
                if let r = Range(pre, in: buffer) {
                    let text = String(buffer[r])
                    events.append(contentsOf: emitText(text))
                }
            }

            let isClose = (Range(m.range(at: 1), in: buffer)
                .map { !buffer[$0].isEmpty } ?? false)

            let tagName = Range(m.range(at: 2), in: buffer)
                .map { String(buffer[$0]) } ?? ""

            if !isClose {
                state = .inTag(tagName)
            } else {
                if case .inTag(let current) = state, current == tagName {
                    state = .outside
                    events.append(.outside)
                }
            }
            
            pos = Range(m.range, in: buffer)!.upperBound
        }

        return events
    }

    private func emitText(_ text: String) -> [ParseEvent] {
        guard !text.isEmpty else { return [] }
        if case .inTag(let name) = state {
            return [.inTag(name: name, content: text)]
        }
        return []
    }
}
