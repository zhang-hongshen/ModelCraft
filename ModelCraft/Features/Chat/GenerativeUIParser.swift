//
//  GenerativeUIParser.swift
//  ModelCraft
//
//  Created by Hongshen on 10/10/26.
//

import Foundation

/// One component of a `ui` block. A block is a JSON array of components; `type` picks the
/// component and the other fields are read by that component only. Containers nest other
/// components in `children`. Types and fields follow SwiftUI names where one exists.
///
/// Every field is optional because a block is rendered while it streams, when the newest
/// component may not have its `type` or other fields yet. Decoding is lenient so one
/// mistyped value does not discard the block: numbers, Booleans, and strings convert into
/// each other where the field needs it, and a component that cannot be decoded is dropped.
struct GenerativeUIComponent: Decodable {
    var type: String?
    var text: String?
    var title: String?
    var icon: String?
    var style: String?
    var kind: String?
    var label: String?
    var value: String?
    var detail: String?
    var footer: String?
    var trend: String?
    var items: [String]?
    var columns: [String]?
    var rows: [[String]]?
    var x: String?
    var y: String?
    var points: [GenerativeUIChartPoint]?
    var places: [GenerativeUIPlace]?
    var send: String?
    var url: String?
    var submit: String?
    var fields: [GenerativeUIFormField]?
    var children: [GenerativeUIComponent]?

    // Layout
    var alignment: String?
    var axis: String?
    var spacing: Double?
    var minWidth: Double?
    var expanded: Bool?

    // Ranges for `gauge` and `progressView`
    var minimum: Double?
    var maximum: Double?
    var total: Double?

    // Modifiers available on every component
    var font: String?
    var weight: String?
    var color: String?
    var background: String?
    var padding: Double?
    var cornerRadius: Double?
    var width: Double?
    var height: Double?
    var fillWidth: Bool?

    /// `value` read as a number, for gauges and progress views.
    var numberValue: Double? {
        value.flatMap(Double.init)
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, title, icon, style, kind, label, value, detail, footer, trend
        case items, columns, rows, x, y, points, places, send, url, submit, fields, children
        case alignment, axis, spacing, minWidth, expanded, minimum, maximum, total
        case font, weight, color, background, padding, cornerRadius, width, height, fillWidth
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = container.lenientString(.type)
        text = container.lenientString(.text)
        title = container.lenientString(.title)
        icon = container.lenientString(.icon)
        style = container.lenientString(.style)
        kind = container.lenientString(.kind)
        label = container.lenientString(.label)
        value = container.lenientString(.value)
        detail = container.lenientString(.detail)
        footer = container.lenientString(.footer)
        trend = container.lenientString(.trend)
        items = container.lenientStrings(.items)
        columns = container.lenientStrings(.columns)
        rows = (try? container.decode([[LenientString]].self, forKey: .rows))?
            .map { $0.map(\.value) }
        x = container.lenientString(.x)
        y = container.lenientString(.y)
        points = container.lossyArray(.points)
        places = container.lossyArray(.places)
        send = container.lenientString(.send)
        url = container.lenientString(.url)
        submit = container.lenientString(.submit)
        fields = container.lossyArray(.fields)
        children = container.lossyArray(.children)
        alignment = container.lenientString(.alignment)
        axis = container.lenientString(.axis)
        spacing = container.lenientDouble(.spacing)
        minWidth = container.lenientDouble(.minWidth)
        expanded = container.lenientBool(.expanded)
        minimum = container.lenientDouble(.minimum)
        maximum = container.lenientDouble(.maximum)
        total = container.lenientDouble(.total)
        font = container.lenientString(.font)
        weight = container.lenientString(.weight)
        color = container.lenientString(.color)
        background = container.lenientString(.background)
        padding = container.lenientDouble(.padding)
        cornerRadius = container.lenientDouble(.cornerRadius)
        width = container.lenientDouble(.width)
        height = container.lenientDouble(.height)
        fillWidth = container.lenientBool(.fillWidth)
    }
}

struct GenerativeUIChartPoint: Decodable {
    var label: String?
    var value: Double?
    var series: String?

    private enum CodingKeys: String, CodingKey { case label, value, series }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.lenientString(.label)
        value = container.lenientDouble(.value)
        series = container.lenientString(.series)
    }
}

struct GenerativeUIPlace: Decodable {
    var title: String?
    var latitude: Double?
    var longitude: Double?

    private enum CodingKeys: String, CodingKey { case title, latitude, longitude }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenientString(.title)
        latitude = container.lenientDouble(.latitude)
        longitude = container.lenientDouble(.longitude)
    }
}

struct GenerativeUIFormField: Decodable {
    var label: String?
    /// `text`, `toggle`, `picker`, `slider`, `stepper`, or `date`.
    var kind: String?
    var value: String?
    var on: Bool?
    var options: [String]?
    var minimum: Double?
    var maximum: Double?
    var step: Double?

    private enum CodingKeys: String, CodingKey {
        case label, kind, value, on, options, minimum, maximum, step
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = container.lenientString(.label)
        kind = container.lenientString(.kind)
        value = container.lenientString(.value)
        on = container.lenientBool(.on)
        options = container.lenientStrings(.options)
        minimum = container.lenientDouble(.minimum)
        maximum = container.lenientDouble(.maximum)
        step = container.lenientDouble(.step)
    }
}

/// A string read from a JSON string, number, or Boolean.
private struct LenientString: Decodable {
    let value: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let number = try? container.decode(Double.self) {
            value = number == number.rounded() && abs(number) < 1e15
                ? String(Int(number)) : String(number)
        } else if let bool = try? container.decode(Bool.self) {
            value = String(bool)
        } else {
            value = ""
        }
    }
}

/// An element that decodes to `nil` instead of failing its array.
private struct Lossy<Element: Decodable>: Decodable {
    let element: Element?

    init(from decoder: any Decoder) throws {
        element = try? Element(from: decoder)
    }
}

private extension KeyedDecodingContainer {

    func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(LenientString.self, forKey: key))?.value
    }

    func lenientStrings(_ key: Key) -> [String]? {
        (try? decodeIfPresent([LenientString].self, forKey: key))?.map(\.value)
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let number = try? decodeIfPresent(Double.self, forKey: key) { return number }
        return lenientString(key).flatMap(Double.init)
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        return lenientString(key).map { $0 == "true" }
    }

    func lossyArray<Element: Decodable>(_ key: Key) -> [Element]? {
        (try? decodeIfPresent([Lossy<Element>].self, forKey: key))?.compactMap(\.element)
    }
}

/// A run of assistant content: leading model reasoning, Markdown text, or a `ui` block.
/// Segments are identified by their first line so they keep their identity while content streams.
enum MessageContentSegment: Identifiable {
    case thinking(text: String, isFinished: Bool)
    case markdown(id: Int, text: String)
    /// `components` is `nil` until the streaming block has something to show.
    case ui(id: Int, components: [GenerativeUIComponent]?)

    var id: Int {
        switch self {
        case .thinking: -1
        case .markdown(let id, _), .ui(let id, _): id
        }
    }

    /// Splits content at fenced blocks tagged `ui`. A block that is still streaming is
    /// rendered from its JSON so far. A finished block that is not valid JSON stays
    /// Markdown, so it shows as a code block. A `ui` fence inside another code block is
    /// ordinary code. Reasoning is the text between a leading `<think>` and `</think>`.
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

        /// Adds a finished block as UI, or as a Markdown code block when it is not valid JSON.
        func finishBlock(start: Int, closingLine: Substring?) {
            if let components = decode(uiLines.joined(separator: "\n")) {
                segments.append(.ui(id: start, components: components))
            } else {
                markdownStart = start
                markdown = [lines[start]] + uiLines + (closingLine.map { [$0] } ?? [])
            }
            uiLines.removeAll()
        }

        for (number, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let start = uiStart {
                if trimmed == "```" {
                    uiStart = nil
                    finishBlock(start: start, closingLine: line)
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
                finishBlock(start: start, closingLine: nil)
            } else {
                let partial = completingPartialJSON(uiLines.joined(separator: "\n"))
                segments.append(.ui(id: start, components: decode(partial)))
            }
        }
        flushMarkdown()
        return segments
    }

    private static func decode(_ json: String) -> [GenerativeUIComponent]? {
        (try? JSONDecoder().decode([Lossy<GenerativeUIComponent>].self, from: Data(json.utf8)))?
            .compactMap(\.element)
    }

    /// Turns the beginning of a streaming JSON document into valid JSON so it can be shown
    /// before it is finished. It keeps the longest prefix that ends after a complete value
    /// (or inside a string value), then closes the open string, objects, and arrays.
    /// For example, `[{"type": "text", "text": "Hel` becomes `[{"type": "text", "text": "Hel"}]`.
    static func completingPartialJSON(_ json: String) -> String {
        let characters = Array(json)
        var openBrackets: [Character] = []
        var expectsKey = false
        var isInString = false
        var isKey = false
        var isEscaped = false
        // The length of the prefix to keep, and the text that closes it.
        var keptLength = 0
        var closing = ""

        func closingBrackets() -> String {
            String(openBrackets.reversed().map { $0 == "{" ? "}" : "]" })
        }

        for (index, character) in characters.enumerated() {
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                // A value string can be cut anywhere except right after a backslash.
                if !isKey, !isEscaped {
                    keptLength = index + 1
                    closing = (isInString ? "\"" : "") + closingBrackets()
                }
                continue
            }
            switch character {
            case "\"":
                isInString = true
                isKey = openBrackets.last == "{" && expectsKey
            case "{", "[":
                openBrackets.append(character)
                expectsKey = character == "{"
                keptLength = index + 1
                closing = closingBrackets()
            case "}", "]":
                _ = openBrackets.popLast()
                expectsKey = false
                keptLength = index + 1
                closing = closingBrackets()
            case ":":
                expectsKey = false
            case ",":
                // Everything before the comma is complete, including a number or literal.
                keptLength = index
                closing = closingBrackets()
                expectsKey = openBrackets.last == "{"
            default:
                break
            }
        }
        return String(characters[..<keptLength]) + closing
    }
}
