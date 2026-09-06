//
//  CodeStructureParser.swift
//  ModelCraft
//

import Foundation
import SwiftParser
import SwiftSyntax
import TreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterGo
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterTSX
import TreeSitterTypeScript

struct CodeSymbolOccurrence {
    enum Role: String {
        case definition
        case reference
    }

    let name: String
    let qualifiedName: String
    let role: Role
    let kind: String
    let container: String?
    let startLine: Int
    let endLine: Int
    let signature: String
}

struct CodeCallEdge {
    let caller: String
    let callee: String
    let line: Int
    let signature: String
}

struct CodeStructure {
    let symbols: [CodeSymbolOccurrence]
    let calls: [CodeCallEdge]
}

enum CodeStructureParser {
    static func parse(_ source: String, fileExtension: String) -> CodeStructure? {
        if fileExtension == "swift" {
            return SwiftSourceStructureParser.parse(source)
        }
        guard let language = TreeSitterLanguage(fileExtension: fileExtension) else { return nil }
        return TreeSitterSourceStructureParser.parse(source, language: language)
    }
}

private enum SwiftSourceStructureParser {
    static func parse(_ source: String) -> CodeStructure {
        let tree = SwiftParser.Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: "", tree: tree)
        let lines = source.components(separatedBy: .newlines)
        var symbols: [CodeSymbolOccurrence] = []
        var calls: [CodeCallEdge] = []

        func lineRange(_ syntax: some SyntaxProtocol) -> (Int, Int) {
            let start = converter.location(for: syntax.positionAfterSkippingLeadingTrivia).line
            let end = converter.location(for: syntax.endPositionBeforeTrailingTrivia).line
            return (start, max(start, end))
        }

        func signature(at line: Int) -> String {
            guard lines.indices.contains(line - 1) else { return "" }
            return String(lines[line - 1].trimmingCharacters(in: .whitespaces).prefix(300))
        }

        func definition(in syntax: Syntax) -> (name: String, kind: String)? {
            if let node = syntax.as(ClassDeclSyntax.self) { return (node.name.text, "class") }
            if let node = syntax.as(StructDeclSyntax.self) { return (node.name.text, "struct") }
            if let node = syntax.as(EnumDeclSyntax.self) { return (node.name.text, "enum") }
            if let node = syntax.as(ProtocolDeclSyntax.self) { return (node.name.text, "protocol") }
            if let node = syntax.as(ActorDeclSyntax.self) { return (node.name.text, "actor") }
            if let node = syntax.as(ExtensionDeclSyntax.self) {
                return (node.extendedType.trimmedDescription, "extension")
            }
            if let node = syntax.as(FunctionDeclSyntax.self) { return (node.name.text, "function") }
            if syntax.is(InitializerDeclSyntax.self) { return ("init", "initializer") }
            if syntax.is(DeinitializerDeclSyntax.self) { return ("deinit", "deinitializer") }
            if let node = syntax.as(TypeAliasDeclSyntax.self) { return (node.name.text, "typealias") }
            return nil
        }

        func calledName(_ expression: ExprSyntax) -> String? {
            if let reference = expression.as(DeclReferenceExprSyntax.self) {
                return reference.baseName.text
            }
            if let member = expression.as(MemberAccessExprSyntax.self) {
                return member.declName.baseName.text
            }
            return nil
        }

        func isCallReference(_ syntax: Syntax) -> Bool {
            var parent = syntax.parent
            for _ in 0..<3 {
                guard let current = parent else { return false }
                if current.is(FunctionCallExprSyntax.self) { return true }
                guard current.is(MemberAccessExprSyntax.self)
                        || current.is(DeclReferenceExprSyntax.self) else { return false }
                parent = current.parent
            }
            return false
        }

        func walk(_ syntax: Syntax, containers: [String], callable: String?) {
            var nestedContainers = containers
            var nestedCallable = callable
            if let declaration = definition(in: syntax) {
                let qualifiedName = (containers + [declaration.name]).joined(separator: ".")
                let range = lineRange(syntax)
                symbols.append(CodeSymbolOccurrence(
                    name: declaration.name,
                    qualifiedName: qualifiedName,
                    role: .definition,
                    kind: declaration.kind,
                    container: containers.last,
                    startLine: range.0,
                    endLine: range.1,
                    signature: signature(at: range.0)))
                nestedContainers.append(declaration.name)
                if declaration.kind == "function"
                    || declaration.kind == "initializer"
                    || declaration.kind == "deinitializer" {
                    nestedCallable = qualifiedName
                }
            }

            if let declaration = syntax.as(VariableDeclSyntax.self) {
                for binding in declaration.bindings {
                    guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    let range = lineRange(binding)
                    let name = identifier.identifier.text
                    symbols.append(CodeSymbolOccurrence(
                        name: name,
                        qualifiedName: (nestedContainers + [name]).joined(separator: "."),
                        role: .definition,
                        kind: declaration.bindingSpecifier.text,
                        container: nestedContainers.last,
                        startLine: range.0,
                        endLine: range.1,
                        signature: signature(at: range.0)))
                }
            }
            if let declaration = syntax.as(EnumCaseDeclSyntax.self) {
                for element in declaration.elements {
                    let range = lineRange(element)
                    let name = element.name.text
                    symbols.append(CodeSymbolOccurrence(
                        name: name,
                        qualifiedName: (nestedContainers + [name]).joined(separator: "."),
                        role: .definition,
                        kind: "enum_case",
                        container: nestedContainers.last,
                        startLine: range.0,
                        endLine: range.1,
                        signature: signature(at: range.0)))
                }
            }

            if let call = syntax.as(FunctionCallExprSyntax.self),
               let callee = calledName(call.calledExpression) {
                let range = lineRange(call)
                let caller = nestedCallable ?? nestedContainers.last ?? "<file>"
                symbols.append(CodeSymbolOccurrence(
                    name: callee,
                    qualifiedName: callee,
                    role: .reference,
                    kind: "call",
                    container: caller,
                    startLine: range.0,
                    endLine: range.1,
                    signature: signature(at: range.0)))
                calls.append(CodeCallEdge(
                    caller: caller,
                    callee: callee,
                    line: range.0,
                    signature: signature(at: range.0)))
            } else if let reference = syntax.as(DeclReferenceExprSyntax.self),
                      !isCallReference(syntax) {
                let range = lineRange(reference)
                let name = reference.baseName.text
                symbols.append(CodeSymbolOccurrence(
                    name: name,
                    qualifiedName: name,
                    role: .reference,
                    kind: "reference",
                    container: nestedCallable ?? nestedContainers.last,
                    startLine: range.0,
                    endLine: range.1,
                    signature: signature(at: range.0)))
            }

            for child in syntax.children(viewMode: .sourceAccurate) {
                walk(child, containers: nestedContainers, callable: nestedCallable)
            }
        }

        walk(Syntax(tree), containers: [], callable: nil)
        return CodeStructure(symbols: symbols, calls: calls)
    }
}

private struct TreeSitterLanguage {
    let pointer: UnsafePointer<TSLanguage>
    let definitionKinds: [String: String]
    let callKinds: Set<String>

    init?(fileExtension: String) {
        callKinds = ["call", "call_expression", "invocation_expression"]
        switch fileExtension {
        case "py", "pyi":
            pointer = tree_sitter_python()
            definitionKinds = ["class_definition": "class", "function_definition": "function"]
        case "js", "jsx":
            pointer = tree_sitter_javascript()
            definitionKinds = Self.javaScriptDefinitions
        case "ts":
            pointer = tree_sitter_typescript()
            definitionKinds = Self.javaScriptDefinitions.merging([
                "interface_declaration": "interface", "type_alias_declaration": "typealias"
            ]) { current, _ in current }
        case "tsx":
            pointer = tree_sitter_tsx()
            definitionKinds = Self.javaScriptDefinitions.merging([
                "interface_declaration": "interface", "type_alias_declaration": "typealias"
            ]) { current, _ in current }
        case "c", "h", "m":
            pointer = tree_sitter_c()
            definitionKinds = Self.cDefinitions
        case "cc", "cpp", "cxx", "hpp", "mm":
            pointer = tree_sitter_cpp()
            definitionKinds = Self.cDefinitions.merging([
                "class_specifier": "class", "namespace_definition": "namespace"
            ]) { current, _ in current }
        case "cs":
            pointer = tree_sitter_c_sharp()
            definitionKinds = Self.objectDefinitions
        case "go":
            pointer = tree_sitter_go()
            definitionKinds = [
                "function_declaration": "function", "method_declaration": "method",
                "type_spec": "type"
            ]
        case "java":
            pointer = tree_sitter_java()
            definitionKinds = Self.objectDefinitions
        case "rb":
            pointer = tree_sitter_ruby()
            definitionKinds = ["class": "class", "module": "module", "method": "method"]
        case "rs":
            pointer = tree_sitter_rust()
            definitionKinds = [
                "function_item": "function", "struct_item": "struct", "enum_item": "enum",
                "trait_item": "trait", "impl_item": "implementation", "type_item": "typealias"
            ]
        case "sh", "bash", "zsh":
            pointer = tree_sitter_bash()
            definitionKinds = ["function_definition": "function"]
        default:
            return nil
        }
    }

    private static let javaScriptDefinitions = [
        "class_declaration": "class", "function_declaration": "function",
        "method_definition": "method", "variable_declarator": "variable"
    ]
    private static let cDefinitions = [
        "function_definition": "function", "struct_specifier": "struct",
        "enum_specifier": "enum", "type_definition": "typealias"
    ]
    private static let objectDefinitions = [
        "class_declaration": "class", "interface_declaration": "interface",
        "enum_declaration": "enum", "method_declaration": "method",
        "constructor_declaration": "constructor"
    ]
}

private enum TreeSitterSourceStructureParser {
    static func parse(_ source: String, language: TreeSitterLanguage) -> CodeStructure? {
        guard let parser = ts_parser_new() else { return nil }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, language.pointer) else { return nil }

        let bytes = Array(source.utf8)
        guard let tree = bytes.withUnsafeBufferPointer({ buffer in
            ts_parser_parse_string(parser, nil, buffer.baseAddress, UInt32(buffer.count))
        }) else { return nil }
        defer { ts_tree_delete(tree) }

        let sourceLines = source.components(separatedBy: .newlines)
        var symbols: [CodeSymbolOccurrence] = []
        var calls: [CodeCallEdge] = []

        func nodeType(_ node: TSNode) -> String {
            String(cString: ts_node_type(node))
        }

        func field(_ name: String, of node: TSNode) -> TSNode? {
            let child = name.withCString {
                ts_node_child_by_field_name(node, $0, UInt32(name.utf8.count))
            }
            return ts_node_is_null(child) ? nil : child
        }

        func text(of node: TSNode) -> String {
            let lower = min(Int(ts_node_start_byte(node)), bytes.count)
            let upper = min(Int(ts_node_end_byte(node)), bytes.count)
            guard lower < upper else { return "" }
            return String(decoding: bytes[lower..<upper], as: UTF8.self)
        }

        func name(of node: TSNode, kind: String) -> String? {
            if let named = field("name", of: node) {
                return text(of: named).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if kind == "function", let declarator = field("declarator", of: node) {
                return terminalIdentifier(in: declarator, text: text)
            }
            if kind == "implementation", let type = field("type", of: node) {
                return text(of: type).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return terminalIdentifier(in: node, text: text)
        }

        func line(of node: TSNode) -> Int {
            Int(ts_node_start_point(node).row) + 1
        }

        func endLine(of node: TSNode) -> Int {
            Int(ts_node_end_point(node).row) + 1
        }

        func signature(at line: Int) -> String {
            guard sourceLines.indices.contains(line - 1) else { return "" }
            return String(sourceLines[line - 1].trimmingCharacters(in: .whitespaces).prefix(300))
        }

        func calleeName(of node: TSNode) -> String? {
            let expression = field("function", of: node)
                ?? field("method", of: node)
                ?? field("name", of: node)
            guard let expression else { return nil }
            return terminalIdentifier(in: expression, text: text)
        }

        func contains(_ parent: TSNode, _ child: TSNode) -> Bool {
            ts_node_start_byte(parent) <= ts_node_start_byte(child)
                && ts_node_end_byte(parent) >= ts_node_end_byte(child)
        }

        func walk(
            _ node: TSNode,
            containers: [String],
            callable: String?,
            suppressReference: Bool = false
        ) {
            let type = nodeType(node)
            var nestedContainers = containers
            var nestedCallable = callable
            var suppressedRoots: [TSNode] = []

            if let kind = language.definitionKinds[type],
               let name = name(of: node, kind: kind), !name.isEmpty {
                let qualified = (containers + [name]).joined(separator: ".")
                let start = line(of: node)
                symbols.append(CodeSymbolOccurrence(
                    name: name,
                    qualifiedName: qualified,
                    role: .definition,
                    kind: kind,
                    container: containers.last,
                    startLine: start,
                    endLine: max(start, endLine(of: node)),
                    signature: signature(at: start)))
                nestedContainers.append(name)
                if ["function", "method", "constructor"].contains(kind) {
                    nestedCallable = qualified
                }
                if let nameNode = field("name", of: node) ?? field("declarator", of: node) {
                    suppressedRoots.append(nameNode)
                }
            }

            if language.callKinds.contains(type), let callee = calleeName(of: node), !callee.isEmpty {
                let start = line(of: node)
                let caller = nestedCallable ?? nestedContainers.last ?? "<file>"
                symbols.append(CodeSymbolOccurrence(
                    name: callee,
                    qualifiedName: callee,
                    role: .reference,
                    kind: "call",
                    container: caller,
                    startLine: start,
                    endLine: max(start, endLine(of: node)),
                    signature: signature(at: start)))
                calls.append(CodeCallEdge(
                    caller: caller,
                    callee: callee,
                    line: start,
                    signature: signature(at: start)))
                if let callTarget = field("function", of: node)
                    ?? field("method", of: node)
                    ?? field("name", of: node) {
                    suppressedRoots.append(callTarget)
                }
            } else if !suppressReference,
                      ["identifier", "field_identifier", "property_identifier", "type_identifier", "constant"].contains(type) {
                let name = text(of: node).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let start = line(of: node)
                    symbols.append(CodeSymbolOccurrence(
                        name: name,
                        qualifiedName: name,
                        role: .reference,
                        kind: "reference",
                        container: nestedCallable ?? nestedContainers.last,
                        startLine: start,
                        endLine: max(start, endLine(of: node)),
                        signature: signature(at: start)))
                }
            }

            for index in 0..<ts_node_named_child_count(node) {
                let child = ts_node_named_child(node, index)
                walk(
                    child,
                    containers: nestedContainers,
                    callable: nestedCallable,
                    suppressReference: suppressReference
                        || suppressedRoots.contains { contains($0, child) })
            }
        }

        walk(ts_tree_root_node(tree), containers: [], callable: nil)
        return CodeStructure(symbols: symbols, calls: calls)
    }

    private static func terminalIdentifier(
        in node: TSNode,
        text: (TSNode) -> String
    ) -> String? {
        let type = String(cString: ts_node_type(node))
        if type == "identifier" || type == "field_identifier" || type == "property_identifier"
            || type == "type_identifier" || type == "constant" {
            return text(node).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let count = ts_node_named_child_count(node)
        guard count > 0 else { return nil }
        for offset in 0..<count {
            let index = count - offset - 1
            if let value = terminalIdentifier(in: ts_node_named_child(node, index), text: text) {
                return value
            }
        }
        return nil
    }
}
