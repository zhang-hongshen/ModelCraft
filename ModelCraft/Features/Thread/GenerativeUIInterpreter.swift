//
//  GenerativeUIInterpreter.swift
//  ModelCraft
//
//  Created by Hongshen on 10/15/26.
//

import SwiftUI
import SwiftParser
import SwiftSyntax

/// An error in a `ui` block, with the line it occurred on.
struct GenerativeUIError: Error {
    let message: String
    let line: Int?

    var description: String {
        line.map { "Line \($0): \(message)" } ?? message
    }
}

// MARK: - Values

/// A value while a `ui` block runs. SwiftUI values such as views, colors, and fonts are
/// values too, so helpers and computed properties can return them. Built-in value types
/// such as shapes, chart marks, and coordinates are records named after their SwiftUI type.
indirect enum UIValue: Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case date(Date)
    case array([UIValue])
    case dictionary([UIValue: UIValue])
    case tuple([UIValue], labels: [String?])
    case record(String, [String: UIValue])
    case enumCase(String, String)
    /// An implicit member such as `.blue` or `.system(size: 20)`; its use decides its type.
    case member(String, [UIArgument])
    case range(UIValue, UIValue, closed: Bool)
    case type(String)
    case keyPath([String])
    case color(Color)
    case font(Font)
    case style(UIReference<AnyShapeStyle>)
    case view(UIReference<AnyView>)
    case binding(UIBinding)
    case closure(UIClosure)
    /// The views of an `if` or `switch`, kept together so their siblings keep their positions.
    case group([UIValue])
    /// The content of a `ForEach`, one item per element, identified by `ids`.
    case each(ids: [UIValue], items: [UIValue])

    static func view(_ view: some View) -> UIValue {
        .view(UIReference(AnyView(view)))
    }

    var number: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        case .string(let value): Double(value)
        case .member("infinity", _): .infinity
        default: nil
        }
    }

    var integer: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.isFinite: Int(value)
        case .string(let value): Int(value)
        default: nil
        }
    }

    /// The name of an enum case or implicit member, such as `leading` for `.leading`.
    var memberName: String? {
        switch self {
        case .member(let name, _), .enumCase(_, let name): name
        default: nil
        }
    }

    var memberArguments: [UIArgument] {
        if case .member(_, let arguments) = self { arguments } else { [] }
    }

    /// The text Swift shows for the value in string interpolation.
    var text: String {
        switch self {
        case .null: "nil"
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .date(let value): value.formatted()
        case .array(let values): "[" + values.map(\.quotedText).joined(separator: ", ") + "]"
        case .dictionary(let values):
            values.isEmpty ? "[:]" : "[" + values.map { "\($0.key.quotedText): \($0.value.quotedText)" }.joined(separator: ", ") + "]"
        case .tuple(let values, let labels):
            "(" + zip(values, labels).map { ($1.map { "\($0): " } ?? "") + $0.quotedText }.joined(separator: ", ") + ")"
        case .record(let type, let fields):
            "\(type)(" + fields.keys.sorted().map { "\($0): \(fields[$0]!.quotedText)" }.joined(separator: ", ") + ")"
        case .enumCase(_, let name), .member(let name, _): name
        case .range(let lower, let upper, let closed): "\(lower.text)\(closed ? "..." : "..<")\(upper.text)"
        case .type(let name): name
        default: ""
        }
    }

    private var quotedText: String {
        if case .string(let value) = self { "\"\(value)\"" } else { text }
    }

    var typeName: String {
        switch self {
        case .null: "nil"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .date: "Date"
        case .array: "Array"
        case .dictionary: "Dictionary"
        case .tuple: "tuple"
        case .record(let type, _), .enumCase(let type, _): type
        case .member(let name, _): ".\(name)"
        case .range: "Range"
        case .type(let name): "\(name).Type"
        case .keyPath: "KeyPath"
        case .color: "Color"
        case .font: "Font"
        case .style: "ShapeStyle"
        case .view, .group, .each: "View"
        case .binding: "Binding"
        case .closure: "closure"
        }
    }

    /// The elements of a sequence: an array, a range, a dictionary's key-value pairs, or a
    /// string's characters.
    var elements: [UIValue]? {
        switch self {
        case .array(let values): return values
        case .range(let lower, let upper, let closed):
            guard let lower = lower.integer, let upper = upper.integer else { return nil }
            let end = closed ? upper : upper - 1
            return end < lower ? [] : (lower...end).map(UIValue.int)
        case .dictionary(let values):
            return values.sorted { $0.key.text < $1.key.text }
                .map { .tuple([$0.key, $0.value], labels: ["key", "value"]) }
        case .string(let value): return value.map { .string(String($0)) }
        default: return nil
        }
    }

    /// A stored field of a record or tuple.
    func field(_ name: String) -> UIValue? {
        switch self {
        case .record(_, let fields): return fields[name]
        case .tuple(let values, let labels):
            if let index = labels.firstIndex(of: name) { return values[index] }
            return Int(name).flatMap { values.indices.contains($0) ? values[$0] : nil }
        default: return nil
        }
    }
}

struct UIArgument: Hashable {
    let label: String?
    let value: UIValue
}

/// Wraps a value that is not `Hashable`; wrappers compare by identity.
final class UIReference<Value>: Hashable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }

    static func == (lhs: UIReference, rhs: UIReference) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A `$` binding: to a `@State` or `@Binding` property, or to a part of one.
final class UIBinding: Hashable {
    let get: () -> UIValue
    let set: (UIValue) -> Void

    init(get: @escaping () -> UIValue, set: @escaping (UIValue) -> Void) {
        self.get = get
        self.set = set
    }

    static func == (lhs: UIBinding, rhs: UIBinding) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    /// A binding to a stored field of this binding's record.
    func field(_ name: String) -> UIBinding {
        UIBinding(
            get: { [get] in get().field(name) ?? .null },
            set: { [get, set] value in
                if case .record(let type, var fields) = get() {
                    fields[name] = value
                    set(.record(type, fields))
                }
            })
    }

    /// A binding to an element of this binding's array.
    func element(_ index: Int) -> UIBinding {
        UIBinding(
            get: { [get] in
                guard case .array(let values) = get(), values.indices.contains(index) else { return .null }
                return values[index]
            },
            set: { [get, set] value in
                if case .array(var values) = get(), values.indices.contains(index) {
                    values[index] = value
                    set(.array(values))
                }
            })
    }
}

/// A closure or a method reference, with the variables and `self` it captured.
final class UIClosure: Hashable {
    enum Body {
        case closure(ClosureExprSyntax)
        case function(FunctionDeclSyntax)
    }

    let body: Body
    let scopes: [[String: UIVariable]]
    let instance: UIInstance

    init(body: Body, scopes: [[String: UIVariable]], instance: UIInstance) {
        self.body = body
        self.scopes = scopes
        self.instance = instance
    }

    static func == (lhs: UIClosure, rhs: UIClosure) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A variable holds its value, or reads and writes through a binding (`@Binding`
/// properties and `$item` closure parameters).
enum UIVariable {
    case value(UIValue)
    case bound(UIBinding)

    var value: UIValue {
        switch self {
        case .value(let value): value
        case .bound(let binding): binding.get()
        }
    }
}

/// The `@State` values of one view instance. SwiftUI keeps it with the view's identity.
@Observable
final class UIStateStore {
    var values: [String: UIValue]

    init(values: [String: UIValue]) {
        self.values = values
    }
}

/// The `self` of running code: a view's properties and state, or a record or enum case.
final class UIInstance {
    let type: UITypeDecl?
    var fields: [String: UIVariable]
    let store: UIStateStore?
    let value: UIValue?

    init(type: UITypeDecl? = nil, fields: [String: UIVariable] = [:], store: UIStateStore? = nil, value: UIValue? = nil) {
        self.type = type
        self.fields = fields
        self.store = store
        self.value = value
    }
}

// MARK: - Program

/// A struct, class, or enum declared in a `ui` block. Classes behave like structs.
struct UITypeDecl {
    struct Property {
        enum Wrapper { case none, state, binding }

        let name: String
        let wrapper: Wrapper
        let initializer: ExprSyntax?
        let getter: CodeBlockItemListSyntax?
        let returnsView: Bool
        let isStatic: Bool
    }

    let name: String
    let isEnum: Bool
    var conformances: [String]
    var properties: [Property] = []
    var methods: [String: FunctionDeclSyntax] = [:]
    var cases: [(name: String, rawValue: ExprSyntax?)] = []

    var isView: Bool { conformances.contains("View") }

    /// Properties set by the memberwise initializer, in declaration order.
    var storedProperties: [Property] {
        properties.filter { $0.getter == nil && !$0.isStatic }
    }

    func rawValue(of caseName: String) -> ExprSyntax? {
        cases.first { $0.name == caseName }?.rawValue
    }
}

/// A parsed `ui` block: its types, functions, and global constants, and the view it shows.
final class GenerativeUIProgram {
    private(set) var types: [String: UITypeDecl] = [:]
    private(set) var functions: [String: FunctionDeclSyntax] = [:]
    private(set) var globals: [String: UIVariable] = [:]
    /// Views written at the top level, shown when the block has no view type.
    private(set) var rootStatements: [CodeBlockItemSyntax] = []
    private(set) var rootType: String?
    private let converter: SourceLocationConverter

    init(source: String) throws {
        let tree = Parser.parse(source: source)
        converter = SourceLocationConverter(fileName: "", tree: tree)
        if tree.hasError {
            let finder = SyntaxErrorFinder(viewMode: .all)
            finder.walk(tree)
            throw GenerativeUIError(
                message: "The code is not valid Swift.",
                line: finder.position.map { converter.location(for: $0).line })
        }

        var order: [String] = []
        var globalDeclarations: [VariableDeclSyntax] = []
        for item in tree.statements {
            switch item.item {
            case .decl(let decl):
                if let variable = decl.as(VariableDeclSyntax.self) {
                    globalDeclarations.append(variable)
                } else if let function = decl.as(FunctionDeclSyntax.self) {
                    functions[function.name.text] = function
                } else {
                    register(decl, order: &order)
                }
            case .stmt, .expr:
                rootStatements.append(item)
            }
        }
        if rootStatements.isEmpty {
            rootType = types["ContentView"]?.isView == true
                ? "ContentView" : order.first { types[$0]?.isView == true }
            if rootType == nil {
                throw GenerativeUIError(message: "Declare `struct ContentView: View`, or write views at the top level.", line: nil)
            }
        }

        let interpreter = UIInterpreter(program: self, instance: UIInstance(), runtime: nil, send: nil)
        for declaration in globalDeclarations {
            try interpreter.declare(declaration)
        }
        globals = interpreter.scopes[0]
    }

    func line(_ node: some SyntaxProtocol) -> Int {
        converter.location(for: node.positionAfterSkippingLeadingTrivia).line
    }

    /// The type whose case is named `name`, when exactly one enum has such a case.
    func enumType(withCase name: String) -> String? {
        let matches = types.values.filter { $0.isEnum && $0.cases.contains { $0.name == name } }
        return matches.count == 1 ? matches[0].name : nil
    }

    private func register(_ decl: DeclSyntax, order: inout [String]) {
        let name: String
        let isEnum: Bool
        let inheritance: InheritanceClauseSyntax?
        let members: MemberBlockSyntax
        if let declaration = decl.as(StructDeclSyntax.self) {
            (name, isEnum, inheritance, members) = (declaration.name.text, false, declaration.inheritanceClause, declaration.memberBlock)
        } else if let declaration = decl.as(ClassDeclSyntax.self) {
            (name, isEnum, inheritance, members) = (declaration.name.text, false, declaration.inheritanceClause, declaration.memberBlock)
        } else if let declaration = decl.as(EnumDeclSyntax.self) {
            (name, isEnum, inheritance, members) = (declaration.name.text, true, declaration.inheritanceClause, declaration.memberBlock)
        } else if let declaration = decl.as(ExtensionDeclSyntax.self) {
            let extended = declaration.extendedType.trimmedDescription
            (name, isEnum, inheritance, members) = (extended, types[extended]?.isEnum ?? false, declaration.inheritanceClause, declaration.memberBlock)
        } else {
            return
        }
        let conformances = inheritance?.inheritedTypes.map(\.type.trimmedDescription) ?? []
        var type = types[name] ?? UITypeDecl(name: name, isEnum: isEnum, conformances: [])
        type.conformances += conformances

        for member in members.members {
            let decl = member.decl
            if let variable = decl.as(VariableDeclSyntax.self) {
                type.properties += Self.properties(of: variable)
            } else if let function = decl.as(FunctionDeclSyntax.self) {
                type.methods[function.name.text] = function
            } else if let enumCase = decl.as(EnumCaseDeclSyntax.self) {
                for element in enumCase.elements {
                    type.cases.append((element.name.text, element.rawValue?.value))
                }
            } else {
                register(decl, order: &order)
            }
        }
        types[name] = type
        if !order.contains(name) {
            order.append(name)
        }
    }

    private static func properties(of variable: VariableDeclSyntax) -> [UITypeDecl.Property] {
        let attributes = variable.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
        let wrapper: UITypeDecl.Property.Wrapper =
            attributes.contains("Binding") ? .binding
            : attributes.contains { ["State", "StateObject", "ObservedObject", "Bindable"].contains($0) } ? .state
            : .none
        let isStatic = variable.modifiers.contains { $0.name.text == "static" }
        let isViewBuilder = attributes.contains("ViewBuilder")
        return variable.bindings.compactMap { binding in
            guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { return nil }
            var getter: CodeBlockItemListSyntax?
            switch binding.accessorBlock?.accessors {
            case .getter(let items):
                getter = items
            case .accessors(let accessors):
                getter = accessors.first { $0.accessorSpecifier.text == "get" }?.body?.statements
            case nil:
                break
            }
            return UITypeDecl.Property(
                name: name,
                wrapper: wrapper,
                initializer: binding.initializer?.value,
                getter: getter,
                returnsView: isViewBuilder || binding.typeAnnotation?.type.trimmedDescription.contains("View") == true,
                isStatic: isStatic)
        }
    }
}

/// Finds the first unexpected or missing piece of syntax.
private final class SyntaxErrorFinder: SyntaxVisitor {
    var position: AbsolutePosition?

    override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
        if position == nil { position = node.positionAfterSkippingLeadingTrivia }
        return .skipChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if position == nil, token.presence == .missing { position = token.position }
        return .skipChildren
    }
}

// MARK: - Calls

/// The arguments of a call or subscript, unevaluated so views can decide which are closures.
struct UICall {
    let arguments: [(label: String?, expression: ExprSyntax)]
    let trailingClosure: ClosureExprSyntax?
    let additionalClosures: [(label: String, closure: ClosureExprSyntax)]
    let node: Syntax

    init(_ call: FunctionCallExprSyntax) {
        arguments = call.arguments.map { ($0.label?.text, $0.expression) }
        trailingClosure = call.trailingClosure
        additionalClosures = call.additionalTrailingClosures.map { ($0.label.text, $0.closure) }
        node = Syntax(call)
    }

    init(_ call: SubscriptCallExprSyntax) {
        arguments = call.arguments.map { ($0.label?.text, $0.expression) }
        trailingClosure = call.trailingClosure
        additionalClosures = call.additionalTrailingClosures.map { ($0.label.text, $0.closure) }
        node = Syntax(call)
    }

    func expression(_ label: String) -> ExprSyntax? {
        arguments.first { $0.label == label }?.expression
    }

    func unlabeled(_ index: Int) -> ExprSyntax? {
        let unlabeled = arguments.filter { $0.label == nil }
        return unlabeled.indices.contains(index) ? unlabeled[index].expression : nil
    }

    /// A closure passed with `label`, as an argument or as a labeled trailing closure.
    func closure(_ label: String) -> ClosureExprSyntax? {
        expression(label)?.as(ClosureExprSyntax.self)
            ?? additionalClosures.first { $0.label == label }?.closure
    }

    /// The content closure: the trailing closure, or one passed as `content:`.
    var content: ClosureExprSyntax? {
        trailingClosure ?? closure("content")
    }
}

// MARK: - Interpreter

/// Runs the code of a `ui` block: evaluates expressions, runs statements, and builds views.
/// One interpreter runs one view body or one action, with `instance` as `self`.
final class UIInterpreter {
    enum Flow {
        case next
        case returned(UIValue)
        case breakLoop
        case continueLoop
    }

    let program: GenerativeUIProgram
    var instance: UIInstance
    let runtime: GenerativeUIRuntime?
    let send: ((String) -> Void)?
    var scopes: [[String: UIVariable]] = [[:]]
    private var budget = 200_000

    init(program: GenerativeUIProgram, instance: UIInstance, runtime: GenerativeUIRuntime?, send: ((String) -> Void)?) {
        self.program = program
        self.instance = instance
        self.runtime = runtime
        self.send = send
    }

    func fail(_ message: String, _ node: some SyntaxProtocol) -> GenerativeUIError {
        GenerativeUIError(message: message, line: program.line(node))
    }

    private func tick(_ node: some SyntaxProtocol) throws {
        budget -= 1
        if budget < 0 {
            throw fail("The code ran too long. Check for an endless loop.", node)
        }
    }

    func withScope<T>(_ scope: [String: UIVariable] = [:], _ body: () throws -> T) rethrows -> T {
        scopes.append(scope)
        defer { scopes.removeLast() }
        return try body()
    }

    /// Runs `body` with another `self` and captured variables, as a closure does.
    func withContext<T>(instance: UIInstance, scopes: [[String: UIVariable]], _ body: () throws -> T) rethrows -> T {
        let saved = (self.instance, self.scopes)
        self.instance = instance
        self.scopes = scopes
        defer { (self.instance, self.scopes) = saved }
        return try body()
    }

    // MARK: Variables

    func define(_ name: String, _ variable: UIVariable) {
        scopes[scopes.count - 1][name] = variable
    }

    func declare(_ declaration: VariableDeclSyntax) throws {
        for binding in declaration.bindings {
            let value = try binding.initializer.map { try eval($0.value) } ?? .null
            if let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                define(name, .value(value))
            } else if let tuple = binding.pattern.as(TuplePatternSyntax.self), case .tuple(let values, _) = value {
                for (element, value) in zip(tuple.elements, values) {
                    if let name = element.pattern.as(IdentifierPatternSyntax.self)?.identifier.text {
                        define(name, .value(value))
                    }
                }
            } else {
                throw fail("Only simple `let` and `var` declarations are supported.", binding)
            }
        }
    }

    private func local(_ name: String) -> UIVariable? {
        for scope in scopes.reversed() {
            if let variable = scope[name] { return variable }
        }
        return nil
    }

    func lookup(_ name: String, _ node: some SyntaxProtocol) throws -> UIValue {
        if let variable = local(name) {
            return variable.value
        }
        if name.hasPrefix("$"), !name.dropFirst().allSatisfy(\.isNumber) {
            return .binding(try binding(to: String(name.dropFirst()), node))
        }
        if name == "self" {
            return instance.value ?? .null
        }
        if let value = try instanceMember(name) {
            return value
        }
        if let variable = program.globals[name] {
            return variable.value
        }
        if let function = program.functions[name] {
            return .closure(UIClosure(body: .function(function), scopes: [], instance: UIInstance()))
        }
        if program.types[name] != nil || Self.builtinTypes.contains(name) {
            return .type(name)
        }
        throw fail("Cannot find '\(name)' in scope.", node)
    }

    static let builtinTypes: Set<String> = [
        "Color", "Font", "Int", "Double", "Float", "CGFloat", "String", "Bool", "Date", "UUID",
        "Array", "Dictionary", "Set", "Timer", "Calendar", "TimeInterval",
    ]

    /// A property or method of `self`.
    private func instanceMember(_ name: String) throws -> UIValue? {
        if let value = instance.store?.values[name] {
            return value
        }
        if let field = instance.fields[name] {
            return field.value
        }
        guard let type = instance.type else { return nil }
        if let property = type.properties.first(where: { $0.name == name && $0.getter != nil }), let getter = property.getter {
            return try withScope { property.returnsView ? try builderValue(getter) : try runBody(getter) }
        }
        if let method = type.methods[name] {
            return .closure(UIClosure(body: .function(method), scopes: [], instance: instance))
        }
        if let property = type.properties.first(where: { $0.name == name && $0.isStatic }), let initializer = property.initializer {
            return try eval(initializer)
        }
        return nil
    }

    /// The binding `$name` refers to.
    func binding(to name: String, _ node: some SyntaxProtocol) throws -> UIBinding {
        if let variable = local(name) {
            if case .bound(let binding) = variable { return binding }
            throw fail("'\(name)' is a local value; only @State and @Binding properties have a `$` binding.", node)
        }
        if case .bound(let binding)? = instance.fields[name] {
            return binding
        }
        if let store = instance.store, store.values[name] != nil {
            return UIBinding(get: { store.values[name] ?? .null }, set: { store.values[name] = $0 })
        }
        throw fail("Cannot find '$\(name)'; only @State and @Binding properties have a `$` binding.", node)
    }

    /// Writes `value` to the variable, property, field, or element `target` names.
    func assign(_ target: ExprSyntax, _ value: UIValue) throws {
        if let reference = target.as(DeclReferenceExprSyntax.self) {
            try assignVariable(reference.baseName.text, value, reference)
        } else if let access = target.as(MemberAccessExprSyntax.self), let base = access.base {
            let name = access.declName.baseName.text
            if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
                try assignVariable(name, value, access)
                return
            }
            guard case .record(let type, var fields) = try eval(base) else {
                throw fail("Cannot assign to '\(name)'.", access)
            }
            fields[name] = value
            try assign(base, .record(type, fields))
        } else if let subscriptCall = target.as(SubscriptCallExprSyntax.self) {
            let call = UICall(subscriptCall)
            guard let indexExpression = call.unlabeled(0) else {
                throw fail("A subscript needs an index.", subscriptCall)
            }
            let index = try eval(indexExpression)
            switch try eval(subscriptCall.calledExpression) {
            case .array(var values):
                guard let position = index.integer, values.indices.contains(position) else {
                    throw fail("Index \(index.text) is out of range.", subscriptCall)
                }
                values[position] = value
                try assign(subscriptCall.calledExpression, .array(values))
            case .dictionary(var values):
                values[index] = value == .null ? nil : value
                try assign(subscriptCall.calledExpression, .dictionary(values))
            case .null where call.expression("default") != nil:
                try assign(subscriptCall.calledExpression, .dictionary([index: value]))
            default:
                throw fail("Cannot assign through this subscript.", subscriptCall)
            }
        } else if let inner = target.as(ForceUnwrapExprSyntax.self)?.expression ?? target.as(OptionalChainingExprSyntax.self)?.expression {
            try assign(inner, value)
        } else if let tuple = target.as(TupleExprSyntax.self), tuple.elements.count == 1, let inner = tuple.elements.first?.expression {
            try assign(inner, value)
        } else {
            throw fail("Cannot assign to this expression.", target)
        }
    }

    private func assignVariable(_ name: String, _ value: UIValue, _ node: some SyntaxProtocol) throws {
        for index in scopes.indices.reversed() {
            guard let variable = scopes[index][name] else { continue }
            switch variable {
            case .value: scopes[index][name] = .value(value)
            case .bound(let binding): binding.set(value)
            }
            return
        }
        if let store = instance.store, store.values[name] != nil {
            store.values[name] = value
            return
        }
        if let field = instance.fields[name] {
            switch field {
            case .bound(let binding): binding.set(value)
            case .value:
                // Methods of records mutate their own copy, which the caller writes back.
                guard instance.store == nil else {
                    throw fail("Cannot change '\(name)'; mark it @State to change it.", node)
                }
                instance.fields[name] = .value(value)
            }
            return
        }
        throw fail("Cannot find '\(name)' to change it.", node)
    }

    // MARK: Statements

    /// Runs statements in their own scope.
    func run(_ items: CodeBlockItemListSyntax) throws -> Flow {
        try withScope {
            for item in items {
                let flow = try execute(item)
                if case .next = flow { continue }
                return flow
            }
            return .next
        }
    }

    /// Runs a function or getter body and returns its result. A single expression is
    /// returned implicitly.
    func runBody(_ items: CodeBlockItemListSyntax) throws -> UIValue {
        if items.count == 1, let expression = Self.expression(of: items.first!) {
            return try evalValue(expression)
        }
        if case .returned(let value) = try run(items) {
            return value
        }
        return .null
    }

    private static func expression(of item: CodeBlockItemSyntax) -> ExprSyntax? {
        switch item.item {
        case .expr(let expression): expression
        case .stmt(let statement): statement.as(ExpressionStmtSyntax.self)?.expression
        case .decl: nil
        }
    }

    private func execute(_ item: CodeBlockItemSyntax) throws -> Flow {
        try tick(item)
        switch item.item {
        case .decl(let decl):
            guard let variable = decl.as(VariableDeclSyntax.self) else {
                throw fail("Declare functions and types at the top level or in a type.", decl)
            }
            try declare(variable)
            return .next
        case .expr(let expression):
            return try execute(expression)
        case .stmt(let statement):
            return try execute(statement)
        }
    }

    private func execute(_ expression: ExprSyntax) throws -> Flow {
        if let ifExpression = expression.as(IfExprSyntax.self) {
            return try withScope {
                if try conditions(ifExpression.conditions) {
                    return try run(ifExpression.body.statements)
                }
                switch ifExpression.elseBody {
                case .ifExpr(let next): return try execute(ExprSyntax(next))
                case .codeBlock(let block): return try run(block.statements)
                case nil: return .next
                }
            }
        }
        if let switchExpression = expression.as(SwitchExprSyntax.self) {
            return try withMatchingCase(switchExpression) { try run($0) } ?? .next
        }
        _ = try eval(expression)
        return .next
    }

    private func execute(_ statement: StmtSyntax) throws -> Flow {
        if let expression = statement.as(ExpressionStmtSyntax.self) {
            return try execute(expression.expression)
        }
        if let returnStatement = statement.as(ReturnStmtSyntax.self) {
            return .returned(try returnStatement.expression.map { try evalValue($0) } ?? .null)
        }
        if statement.is(BreakStmtSyntax.self) { return .breakLoop }
        if statement.is(ContinueStmtSyntax.self) { return .continueLoop }
        if let guardStatement = statement.as(GuardStmtSyntax.self) {
            if try conditions(guardStatement.conditions) { return .next }
            return try run(guardStatement.body.statements)
        }
        if let forStatement = statement.as(ForStmtSyntax.self) {
            let sequence = try eval(forStatement.sequence)
            guard let elements = sequence.elements else {
                throw fail("Cannot loop over a value of type \(sequence.typeName).", forStatement.sequence)
            }
            for element in elements {
                try tick(forStatement)
                let flow: Flow = try withScope {
                    try bind(forStatement.pattern, to: element)
                    if let condition = forStatement.whereClause?.condition, try !truth(eval(condition), condition) {
                        return .continueLoop
                    }
                    return try run(forStatement.body.statements)
                }
                switch flow {
                case .breakLoop: return .next
                case .returned: return flow
                case .next, .continueLoop: continue
                }
            }
            return .next
        }
        if let whileStatement = statement.as(WhileStmtSyntax.self) {
            while try withScope([:], { try conditions(whileStatement.conditions) }) {
                try tick(whileStatement)
                let flow = try run(whileStatement.body.statements)
                if case .breakLoop = flow { break }
                if case .returned = flow { return flow }
            }
            return .next
        }
        if let repeatStatement = statement.as(RepeatStmtSyntax.self) {
            repeat {
                try tick(repeatStatement)
                let flow = try run(repeatStatement.body.statements)
                if case .breakLoop = flow { break }
                if case .returned = flow { return flow }
            } while try truth(eval(repeatStatement.condition), repeatStatement.condition)
            return .next
        }
        throw fail("This statement is not supported.", statement)
    }

    private func bind(_ pattern: PatternSyntax, to value: UIValue) throws {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) {
            define(identifier.identifier.text, .value(value))
        } else if let tuple = pattern.as(TuplePatternSyntax.self) {
            guard case .tuple(let values, _) = value else {
                throw fail("Cannot destructure a value of type \(value.typeName).", pattern)
            }
            for (element, value) in zip(tuple.elements, values) {
                try bind(element.pattern, to: value)
            }
        } else if let binding = pattern.as(ValueBindingPatternSyntax.self) {
            try bind(binding.pattern, to: value)
        } else if !pattern.is(WildcardPatternSyntax.self) {
            throw fail("This pattern is not supported.", pattern)
        }
    }

    /// Evaluates `if`, `guard`, and `while` conditions; `if let` defines its names in the
    /// current scope.
    func conditions(_ list: ConditionElementListSyntax) throws -> Bool {
        for element in list {
            switch element.condition {
            case .expression(let expression):
                if try !truth(eval(expression), expression) { return false }
            case .optionalBinding(let binding):
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    throw fail("Only `if let name` bindings are supported.", binding)
                }
                let value = try binding.initializer.map { try eval($0.value) } ?? lookup(name, binding)
                if value == .null { return false }
                define(name, .value(value))
            default:
                throw fail("This condition is not supported.", element)
            }
        }
        return true
    }

    func truth(_ value: UIValue, _ node: some SyntaxProtocol) throws -> Bool {
        guard case .bool(let flag) = value else {
            throw fail("Expected a Bool, found \(value.typeName).", node)
        }
        return flag
    }

    /// Runs `body` with the statements of the case that matches the switch subject, with
    /// its bindings in scope; `nil` when no case matches.
    func withMatchingCase<T>(_ switchExpression: SwitchExprSyntax, _ body: (CodeBlockItemListSyntax) throws -> T) throws -> T? {
        let subject = try eval(switchExpression.subject)
        for element in switchExpression.cases {
            guard case .switchCase(let switchCase) = element else { continue }
            let matched: T? = try withScope {
                switch switchCase.label {
                case .default:
                    return try body(switchCase.statements)
                case .case(let label):
                    for item in label.caseItems {
                        guard try matches(item.pattern, subject) else { continue }
                        if let condition = item.whereClause?.condition, try !truth(eval(condition), condition) {
                            continue
                        }
                        return try body(switchCase.statements)
                    }
                    return nil
                }
            }
            if let matched { return matched }
        }
        return nil
    }

    private func matches(_ pattern: PatternSyntax, _ subject: UIValue) throws -> Bool {
        if let expression = pattern.as(ExpressionPatternSyntax.self)?.expression {
            let value = try eval(expression)
            if case .range(let lower, let upper, let closed) = value, let number = subject.number,
               let low = lower.number, let high = upper.number {
                return number >= low && (closed ? number <= high : number < high)
            }
            return equal(value, subject)
        }
        if pattern.is(WildcardPatternSyntax.self) { return true }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) {
            try bind(binding.pattern, to: subject)
            return true
        }
        throw fail("This case pattern is not supported.", pattern)
    }

    // MARK: Expressions

    /// Evaluates an expression where an `if` or `switch` may produce a value.
    func evalValue(_ expression: ExprSyntax) throws -> UIValue {
        if let ifExpression = expression.as(IfExprSyntax.self) {
            return try withScope {
                if try conditions(ifExpression.conditions) {
                    return try runBody(ifExpression.body.statements)
                }
                switch ifExpression.elseBody {
                case .ifExpr(let next): return try evalValue(ExprSyntax(next))
                case .codeBlock(let block): return try runBody(block.statements)
                case nil: return .null
                }
            }
        }
        if let switchExpression = expression.as(SwitchExprSyntax.self) {
            return try withMatchingCase(switchExpression) { try runBody($0) } ?? .null
        }
        return try eval(expression)
    }

    func eval(_ expression: ExprSyntax) throws -> UIValue {
        try tick(expression)
        if let literal = expression.as(IntegerLiteralExprSyntax.self) {
            let text = literal.literal.text.replacingOccurrences(of: "_", with: "")
            guard let value = text.hasPrefix("0x") ? Int(text.dropFirst(2), radix: 16) : Int(text) else {
                throw fail("Invalid integer literal.", literal)
            }
            return .int(value)
        }
        if let literal = expression.as(FloatLiteralExprSyntax.self) {
            return .double(Double(literal.literal.text.replacingOccurrences(of: "_", with: "")) ?? 0)
        }
        if let literal = expression.as(BooleanLiteralExprSyntax.self) {
            return .bool(literal.literal.text == "true")
        }
        if expression.is(NilLiteralExprSyntax.self) {
            return .null
        }
        if let literal = expression.as(StringLiteralExprSyntax.self) {
            return .string(try string(literal))
        }
        if let array = expression.as(ArrayExprSyntax.self) {
            return .array(try array.elements.map { try eval($0.expression) })
        }
        if let dictionary = expression.as(DictionaryExprSyntax.self) {
            guard case .elements(let elements) = dictionary.content else { return .dictionary([:]) }
            var values: [UIValue: UIValue] = [:]
            for element in elements {
                values[try eval(element.key)] = try eval(element.value)
            }
            return .dictionary(values)
        }
        if let reference = expression.as(DeclReferenceExprSyntax.self) {
            return try lookup(reference.baseName.text, reference)
        }
        if let access = expression.as(MemberAccessExprSyntax.self) {
            return try member(access)
        }
        if let call = expression.as(FunctionCallExprSyntax.self) {
            return try self.call(call)
        }
        if let subscriptCall = expression.as(SubscriptCallExprSyntax.self) {
            return try subscriptValue(subscriptCall)
        }
        if let sequence = expression.as(SequenceExprSyntax.self) {
            var folder = OperatorFolder(elements: Array(sequence.elements))
            return try evaluate(folder.fold(), sequence)
        }
        if let prefix = expression.as(PrefixOperatorExprSyntax.self) {
            let value = try eval(prefix.expression)
            switch (prefix.operator.text, value) {
            case ("!", .bool(let flag)): return .bool(!flag)
            case ("-", .int(let number)): return .int(-number)
            case ("-", .double(let number)): return .double(-number)
            case ("+", _): return value
            default: throw fail("Cannot apply '\(prefix.operator.text)' to \(value.typeName).", prefix)
            }
        }
        if let tuple = expression.as(TupleExprSyntax.self) {
            if tuple.elements.count == 1, let element = tuple.elements.first, element.label == nil {
                return try eval(element.expression)
            }
            return .tuple(try tuple.elements.map { try eval($0.expression) }, labels: tuple.elements.map { $0.label?.text })
        }
        if let ternary = expression.as(TernaryExprSyntax.self) {
            return try truth(eval(ternary.condition), ternary.condition)
                ? eval(ternary.thenExpression) : eval(ternary.elseExpression)
        }
        if let closure = expression.as(ClosureExprSyntax.self) {
            return .closure(UIClosure(body: .closure(closure), scopes: scopes, instance: instance))
        }
        if let optional = expression.as(OptionalChainingExprSyntax.self) {
            return try eval(optional.expression)
        }
        if let unwrap = expression.as(ForceUnwrapExprSyntax.self) {
            let value = try eval(unwrap.expression)
            if value == .null {
                throw fail("Unexpectedly found nil while unwrapping a value.", unwrap)
            }
            return value
        }
        if let tryExpression = expression.as(TryExprSyntax.self) {
            if tryExpression.questionOrExclamationMark?.text == "?" {
                return (try? eval(tryExpression.expression)) ?? .null
            }
            return try eval(tryExpression.expression)
        }
        if let awaitExpression = expression.as(AwaitExprSyntax.self) {
            return try eval(awaitExpression.expression)
        }
        if let keyPath = expression.as(KeyPathExprSyntax.self) {
            return .keyPath(keyPath.components.compactMap {
                $0.component.as(KeyPathPropertyComponentSyntax.self)?.declName.baseName.text
            })
        }
        if let ifExpression = expression.as(IfExprSyntax.self) {
            return try evalValue(ExprSyntax(ifExpression))
        }
        if let switchExpression = expression.as(SwitchExprSyntax.self) {
            return try evalValue(ExprSyntax(switchExpression))
        }
        if let specialization = expression.as(GenericSpecializationExprSyntax.self) {
            return try eval(specialization.expression)
        }
        throw fail("This expression is not supported: \(expression.trimmedDescription.prefix(40))", expression)
    }

    private func string(_ literal: StringLiteralExprSyntax) throws -> String {
        var result = ""
        for segment in literal.segments {
            switch segment {
            case .stringSegment(let text):
                result += Self.unescape(text.content.text)
            case .expressionSegment(let interpolation):
                guard let first = interpolation.expressions.first else { continue }
                let value = try eval(first.expression)
                if let specifier = interpolation.expressions.first(where: { $0.label?.text == "specifier" }) {
                    result += Self.format(try eval(specifier.expression).text, [value])
                } else {
                    result += value.text
                }
            }
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var result = ""
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else {
                result.append(character)
                continue
            }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "r": result.append("\r")
            case "0": result.append("\0")
            case "u":
                var digits = ""
                while let digit = iterator.next(), digit != "}" {
                    if digit != "{" { digits.append(digit) }
                }
                if let code = UInt32(digits, radix: 16), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
            default: result.append(next)
            }
        }
        return result
    }

    /// `String(format:)` with numbers and strings.
    static func format(_ format: String, _ values: [UIValue]) -> String {
        let arguments: [any CVarArg] = values.map { value in
            switch value {
            case .int(let number): number
            case .double(let number): number
            default: value.text
            }
        }
        return String(format: format, arguments: arguments)
    }

    private func subscriptValue(_ subscriptCall: SubscriptCallExprSyntax) throws -> UIValue {
        let call = UICall(subscriptCall)
        let base = try eval(subscriptCall.calledExpression)
        guard let indexExpression = call.unlabeled(0) else {
            throw fail("A subscript needs an index.", subscriptCall)
        }
        let index = try eval(indexExpression)
        switch base {
        case .array(let values):
            if case .range(let lower, let upper, let closed) = index, let low = lower.integer, let high = upper.integer {
                let end = closed ? high + 1 : high
                guard low >= 0, end <= values.count, low <= end else {
                    throw fail("Range \(index.text) is out of bounds for \(values.count) elements.", subscriptCall)
                }
                return .array(Array(values[low..<end]))
            }
            guard let position = index.integer, values.indices.contains(position) else {
                throw fail("Index \(index.text) is out of range for \(values.count) elements.", subscriptCall)
            }
            return values[position]
        case .dictionary(let values):
            if let value = values[index] { return value }
            return try call.expression("default").map { try eval($0) } ?? .null
        case .binding(let binding):
            guard let position = index.integer else {
                throw fail("A binding subscript needs an integer index.", subscriptCall)
            }
            return .binding(binding.element(position))
        case .null:
            return try call.expression("default").map { try eval($0) } ?? .null
        default:
            throw fail("Cannot subscript a value of type \(base.typeName).", subscriptCall)
        }
    }

    // MARK: Operators

    private func evaluate(_ node: FoldedExpression, _ sequence: SequenceExprSyntax) throws -> UIValue {
        switch node {
        case .operand(let expression):
            return try eval(expression)
        case .ternary(let condition, let then, let otherwise):
            return try truth(evaluate(condition, sequence), sequence)
                ? eval(then) : evaluate(otherwise, sequence)
        case .binary(let op, let lhs, let rhs):
            switch op {
            case "=":
                guard case .operand(let target) = lhs else { throw fail("Cannot assign to this expression.", sequence) }
                try assign(target, try evaluate(rhs, sequence))
                return .null
            case "+=", "-=", "*=", "/=", "%=":
                guard case .operand(let target) = lhs else { throw fail("Cannot assign to this expression.", sequence) }
                let result = try arithmetic(String(op.dropLast()), eval(target), evaluate(rhs, sequence), sequence)
                try assign(target, result)
                return .null
            case "&&":
                return .bool(try truth(evaluate(lhs, sequence), sequence) && truth(evaluate(rhs, sequence), sequence))
            case "||":
                return .bool(try truth(evaluate(lhs, sequence), sequence) || truth(evaluate(rhs, sequence), sequence))
            case "??":
                let value = try evaluate(lhs, sequence)
                return value == .null ? try evaluate(rhs, sequence) : value
            default:
                return try binary(op, evaluate(lhs, sequence), evaluate(rhs, sequence), sequence)
            }
        }
    }

    func binary(_ op: String, _ lhs: UIValue, _ rhs: UIValue, _ node: some SyntaxProtocol) throws -> UIValue {
        switch op {
        case "==", "===": return .bool(equal(lhs, rhs))
        case "!=", "!==": return .bool(!equal(lhs, rhs))
        case "<", ">", "<=", ">=":
            let order = try compare(lhs, rhs, node)
            return .bool(op == "<" ? order < 0 : op == ">" ? order > 0 : op == "<=" ? order <= 0 : order >= 0)
        case "..<", "...":
            return .range(lhs, rhs, closed: op == "...")
        default:
            return try arithmetic(op, lhs, rhs, node)
        }
    }

    func equal(_ lhs: UIValue, _ rhs: UIValue) -> Bool {
        if let left = lhs.number, let right = rhs.number, lhs.typeName != "String", rhs.typeName != "String" {
            return left == right
        }
        switch (lhs, rhs) {
        case (.enumCase(_, let left), .member(let right, _)), (.member(let left, _), .enumCase(_, let right)):
            return left == right
        default:
            return lhs == rhs
        }
    }

    func compare(_ lhs: UIValue, _ rhs: UIValue, _ node: some SyntaxProtocol) throws -> Int {
        switch (lhs, rhs) {
        case (.string(let left), .string(let right)): return left < right ? -1 : left == right ? 0 : 1
        case (.date(let left), .date(let right)): return left < right ? -1 : left == right ? 0 : 1
        default:
            guard let left = lhs.number, let right = rhs.number else {
                throw fail("Cannot compare \(lhs.typeName) with \(rhs.typeName).", node)
            }
            return left < right ? -1 : left == right ? 0 : 1
        }
    }

    func arithmetic(_ op: String, _ lhs: UIValue, _ rhs: UIValue, _ node: some SyntaxProtocol) throws -> UIValue {
        switch (op, lhs, rhs) {
        case ("+", .string(let left), _): return .string(left + rhs.text)
        case ("+", .array(let left), .array(let right)): return .array(left + right)
        case (_, .int(let left), .int(let right)):
            let (result, overflow): (Int, Bool) = switch op {
            case "+": left.addingReportingOverflow(right)
            case "-": left.subtractingReportingOverflow(right)
            case "*": left.multipliedReportingOverflow(by: right)
            case "/", "%":
                right == 0 ? (0, true) : op == "/" ? left.dividedReportingOverflow(by: right) : left.remainderReportingOverflow(dividingBy: right)
            default: (0, true)
            }
            if overflow {
                throw fail(right == 0 && (op == "/" || op == "%") ? "Division by zero." : "Cannot apply '\(op)' to these integers.", node)
            }
            return .int(result)
        case (_, .date(let date), _) where op == "+" || op == "-":
            guard let seconds = rhs.number else { break }
            return .date(date.addingTimeInterval(op == "+" ? seconds : -seconds))
        default:
            guard let left = lhs.number, let right = rhs.number else { break }
            switch op {
            case "+": return .double(left + right)
            case "-": return .double(left - right)
            case "*": return .double(left * right)
            case "/": return .double(left / right)
            case "%": return .double(left.truncatingRemainder(dividingBy: right))
            default: break
            }
        }
        throw fail("Cannot apply '\(op)' to \(lhs.typeName) and \(rhs.typeName).", node)
    }

    // MARK: Members

    private func member(_ access: MemberAccessExprSyntax) throws -> UIValue {
        let name = access.declName.baseName.text
        guard let base = access.base else {
            if let type = program.enumType(withCase: name) {
                return .enumCase(type, name)
            }
            return name == "infinity" ? .double(.infinity) : .member(name, [])
        }
        if base.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" {
            guard let value = try instanceMember(name) else {
                throw fail("'self' has no member '\(name)'.", access)
            }
            return value
        }
        let value = try eval(base)
        if case .type(let type) = value {
            return try staticMember(type, name, access)
        }
        return try property(value, name, access)
    }

    private func staticMember(_ type: String, _ name: String, _ node: some SyntaxProtocol) throws -> UIValue {
        if let declaration = program.types[type] {
            if declaration.cases.contains(where: { $0.name == name }) {
                return .enumCase(type, name)
            }
            if name == "allCases" {
                return .array(declaration.cases.map { .enumCase(type, $0.name) })
            }
            if let property = declaration.properties.first(where: { $0.name == name && $0.isStatic }) {
                if let initializer = property.initializer {
                    return try withContext(instance: UIInstance(type: declaration), scopes: [[:]]) { try eval(initializer) }
                }
                if let getter = property.getter {
                    return try withContext(instance: UIInstance(type: declaration), scopes: [[:]]) { try runBody(getter) }
                }
            }
            if let method = declaration.methods[name] {
                return .closure(UIClosure(body: .function(method), scopes: [[:]], instance: UIInstance(type: declaration)))
            }
            throw fail("Type '\(type)' has no member '\(name)'.", node)
        }
        switch (type, name) {
        case ("Color", _):
            if let color = UIStyles.color(named: name) { return .color(color) }
        case ("Font", _):
            if let font = UIStyles.font(.member(name, [])) { return .font(font) }
        case ("Double", "pi"), ("CGFloat", "pi"), ("Float", "pi"): return .double(.pi)
        case ("Double", "infinity"), ("CGFloat", "infinity"): return .double(.infinity)
        case ("Int", "max"): return .int(.max)
        case ("Int", "min"): return .int(.min)
        case ("Date", "now"): return .date(.now)
        default: break
        }
        return .member(name, [])
    }

    /// A property of a value: stored or computed fields of records and enum cases, and the
    /// built-in properties of Swift values.
    func property(_ value: UIValue, _ name: String, _ node: some SyntaxProtocol) throws -> UIValue {
        if case .binding(let binding) = value {
            return .binding(binding.field(name))
        }
        if let field = value.field(name) {
            return field
        }
        switch value {
        case .record(let type, _) where !Self.builtinRecordTypes.contains(type), .enumCase(let type, _):
            let fields: [String: UIValue] = if case .record(_, let fields) = value { fields } else { [:] }
            if case .enumCase(let typeName, let caseName) = value, name == "rawValue" {
                return try rawValue(typeName, caseName)
            }
            if case .enumCase = value, name == "id" { return value }
            guard let declaration = program.types[type],
                  let property = declaration.properties.first(where: { $0.name == name && $0.getter != nil }),
                  let getter = property.getter
            else {
                throw fail("Value of type \(type) has no member '\(name)'.", node)
            }
            let instance = UIInstance(type: declaration, fields: fields.mapValues { .value($0) }, value: value)
            return try withContext(instance: instance, scopes: [[:]]) {
                property.returnsView ? try builderValue(getter) : try runBody(getter)
            }
        default:
            break
        }
        switch (value, name) {
        case (.string(let text), "count"): return .int(text.count)
        case (.string(let text), "isEmpty"): return .bool(text.isEmpty)
        case (.string(let text), "first"): return text.first.map { .string(String($0)) } ?? .null
        case (.string(let text), "last"): return text.last.map { .string(String($0)) } ?? .null
        case (.string(let text), "capitalized"): return .string(text.capitalized)
        case (.string(let text), "description"): return .string(text)
        case (.array(let values), "count"): return .int(values.count)
        case (.array(let values), "isEmpty"): return .bool(values.isEmpty)
        case (.array(let values), "first"): return values.first ?? .null
        case (.array(let values), "last"): return values.last ?? .null
        case (.array(let values), "indices"): return .range(.int(0), .int(values.count), closed: false)
        case (.dictionary(let values), "count"): return .int(values.count)
        case (.dictionary(let values), "isEmpty"): return .bool(values.isEmpty)
        case (.dictionary(let values), "keys"): return .array(values.keys.sorted { $0.text < $1.text })
        case (.dictionary(let values), "values"): return .array(values.sorted { $0.key.text < $1.key.text }.map(\.value))
        case (.range(let lower, _, _), "lowerBound"): return lower
        case (.range(_, let upper, _), "upperBound"): return upper
        case (.range, "count"): return .int(value.elements?.count ?? 0)
        case (.int(let number), "description"): return .string(String(number))
        case (.double(let number), "description"): return .string(String(number))
        case (.int(let number), "magnitude"): return .int(abs(number))
        case (.double(let number), "magnitude"): return .double(abs(number))
        case (.bool(let flag), "description"): return .string(String(flag))
        case (.date(let date), "timeIntervalSince1970"): return .double(date.timeIntervalSince1970)
        case (.date(let date), "timeIntervalSinceNow"): return .double(date.timeIntervalSinceNow)
        case (.color(let color), "gradient"): return .style(UIReference(AnyShapeStyle(color.gradient)))
        case (.member, "gradient"):
            if let color = UIStyles.color(value) { return .style(UIReference(AnyShapeStyle(color.gradient))) }
        case (.member(let base, let arguments), _):
            // A chain such as `.title.bold` stays an implicit member for its use to decide.
            return .member(base + "." + name, arguments)
        case (.null, _):
            return .null
        default:
            break
        }
        throw fail("Value of type \(value.typeName) has no member '\(name)'.", node)
    }

    static let builtinRecordTypes: Set<String> = [
        "Image", "Rectangle", "RoundedRectangle", "Circle", "Capsule", "Ellipse", "GridItem",
        "BarMark", "LineMark", "AreaMark", "PointMark", "RuleMark", "SectorMark", "Marker",
        "CLLocationCoordinate2D", "Timer",
    ]

    private func rawValue(_ type: String, _ caseName: String) throws -> UIValue {
        guard let declaration = program.types[type] else { return .string(caseName) }
        if let expression = declaration.rawValue(of: caseName) {
            return try eval(expression)
        }
        if declaration.conformances.contains("Int") {
            return .int(declaration.cases.firstIndex { $0.name == caseName } ?? 0)
        }
        return .string(caseName)
    }

    // MARK: Calls

    private func call(_ call: FunctionCallExprSyntax) throws -> UIValue {
        let arguments = UICall(call)
        let callee = call.calledExpression
        if let reference = callee.as(DeclReferenceExprSyntax.self) {
            let name = reference.baseName.text
            if let variable = local(name) {
                return try callValue(variable.value, arguments, call)
            }
            if let declaration = program.types[name] {
                return try construct(declaration, arguments)
            }
            if let value = try makeView(name, arguments) {
                return value
            }
            if let value = try builtinFunction(name, arguments) {
                return value
            }
            if let method = instance.type?.methods[name] {
                return try callFunction(method, try evaluate(arguments))
            }
            if let function = program.functions[name] {
                return try callFunction(function, try evaluate(arguments))
            }
            return try callValue(try lookup(name, reference), arguments, call)
        }
        if let access = callee.as(MemberAccessExprSyntax.self) {
            let name = access.declName.baseName.text
            guard let baseExpression = access.base else {
                return .member(name, try evaluate(arguments))
            }
            if baseExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "self",
               let method = instance.type?.methods[name] {
                return try callFunction(method, try evaluate(arguments))
            }
            let base = try eval(baseExpression)
            if case .type(let type) = base {
                return try staticCall(type, name, arguments)
            }
            if let modified = try modify(base, name, arguments) {
                return modified
            }
            return try method(base, name, arguments, baseExpression)
        }
        return try callValue(try eval(callee), arguments, call)
    }

    func evaluate(_ call: UICall) throws -> [UIArgument] {
        var arguments = try call.arguments.map { UIArgument(label: $0.label, value: try eval($0.expression)) }
        if let closure = call.trailingClosure {
            arguments.append(UIArgument(label: nil, value: try eval(ExprSyntax(closure))))
        }
        return arguments
    }

    func value(_ call: UICall, _ label: String) throws -> UIValue? {
        try call.expression(label).map { try eval($0) }
    }

    func value(_ call: UICall, at index: Int) throws -> UIValue? {
        try call.unlabeled(index).map { try eval($0) }
    }

    private func callValue(_ value: UIValue, _ call: UICall, _ node: some SyntaxProtocol) throws -> UIValue {
        guard case .closure(let closure) = value else {
            throw fail("Cannot call a value of type \(value.typeName).", node)
        }
        return try invoke(closure, try evaluate(call))
    }

    /// Calls a closure or function value with its captured variables and `self`.
    func invoke(_ closure: UIClosure, _ arguments: [UIArgument]) throws -> UIValue {
        try withContext(instance: closure.instance, scopes: closure.scopes) {
            switch closure.body {
            case .closure(let syntax): try callClosure(syntax, arguments.map(\.value))
            case .function(let function): try callFunction(function, arguments)
            }
        }
    }

    /// Runs a closure's body with its parameters bound, returning its result.
    func callClosure(_ closure: ClosureExprSyntax, _ arguments: [UIValue]) throws -> UIValue {
        try withScope(parameters(of: closure, arguments)) {
            try runBody(closure.statements)
        }
    }

    /// Binds a closure's parameters. A tuple argument is spread over several parameters,
    /// and a `$item` parameter reads and writes through its binding argument.
    func parameters(of closure: ClosureExprSyntax, _ arguments: [UIValue]) -> [String: UIVariable] {
        let names: [String] = switch closure.signature?.parameterClause {
        case .simpleInput(let parameters): parameters.map(\.name.text)
        case .parameterClause(let clause): clause.parameters.map { ($0.secondName ?? $0.firstName).text }
        case nil: []
        }
        var values = arguments
        if names.count > 1, values.count == 1, case .tuple(let elements, _) = values[0] {
            values = elements
        }
        var scope: [String: UIVariable] = [:]
        for (index, value) in values.enumerated() {
            scope["$\(index)"] = .value(value)
            guard names.indices.contains(index) else { continue }
            let name = names[index]
            if case .binding(let binding) = value {
                scope[name.hasPrefix("$") ? String(name.dropFirst()) : name] = .bound(binding)
            } else {
                scope[name] = .value(value)
            }
        }
        return scope
    }

    func callFunction(_ function: FunctionDeclSyntax, _ arguments: [UIArgument]) throws -> UIValue {
        var remaining = arguments
        var scope: [String: UIVariable] = [:]
        for parameter in function.signature.parameterClause.parameters {
            let label = parameter.firstName.text == "_" ? nil : parameter.firstName.text
            let name = (parameter.secondName ?? parameter.firstName).text
            if let index = remaining.firstIndex(where: { $0.label == label }) ?? remaining.firstIndex(where: { $0.label == nil }) {
                scope[name] = .value(remaining.remove(at: index).value)
            } else if let defaultValue = parameter.defaultValue?.value {
                scope[name] = .value(try eval(defaultValue))
            } else {
                throw fail("Missing argument '\(label ?? name)' for \(function.name.text).", function.name)
            }
        }
        guard let body = function.body else { return .null }
        let returnsView = function.signature.returnClause?.type.trimmedDescription.contains("View") == true
            || function.attributes.contains { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "ViewBuilder" }
        return try withScope(scope) {
            returnsView ? try builderValue(body.statements) : try runBody(body.statements)
        }
    }

    /// Creates a value of a declared type: a view, a record with its memberwise
    /// initializer, or an enum case from its raw value.
    private func construct(_ type: UITypeDecl, _ call: UICall) throws -> UIValue {
        let arguments = try evaluate(call)
        if type.isEnum {
            guard let raw = arguments.first?.value else { return .null }
            for item in type.cases where try equal(rawValue(type.name, item.name), raw) {
                return .enumCase(type.name, item.name)
            }
            return .null
        }
        if type.isView {
            return .view(InterpretedView(program: program, type: type, arguments: arguments, runtime: runtime, send: send))
        }
        let fields = try storedFields(of: type, arguments, call.node)
        return .record(type.name, fields.mapValues(\.value))
    }

    /// The stored properties of a new instance: from labeled arguments, then unlabeled
    /// ones in order, then initial values. Initial values can use earlier properties.
    func storedFields(of type: UITypeDecl, _ arguments: [UIArgument], _ node: Syntax?) throws -> [String: UIVariable] {
        var unlabeled = arguments.filter { $0.label == nil }.map(\.value)
        var fields: [String: UIVariable] = [:]
        try withContext(instance: UIInstance(type: type), scopes: [[:]]) {
            for property in type.storedProperties {
                var value: UIValue
                if let argument = arguments.first(where: { $0.label == property.name }) {
                    value = argument.value
                } else if property.initializer == nil, !unlabeled.isEmpty {
                    value = unlabeled.removeFirst()
                } else if let initializer = property.initializer {
                    value = try eval(initializer)
                } else {
                    value = .null
                }
                if case .binding(let binding) = value, property.wrapper == .binding {
                    fields[property.name] = .bound(binding)
                } else {
                    if property.wrapper == .binding {
                        throw GenerativeUIError(message: "Pass a `$` binding to '\(property.name)'.", line: node.map(program.line))
                    }
                    fields[property.name] = .value(value)
                }
                instance.fields[property.name] = fields[property.name]
            }
        }
        return fields
    }

    private func staticCall(_ type: String, _ name: String, _ call: UICall) throws -> UIValue {
        if let declaration = program.types[type], let method = declaration.methods[name] {
            return try withContext(instance: UIInstance(type: declaration), scopes: [[:]]) {
                try callFunction(method, try evaluate(call))
            }
        }
        let arguments = try evaluate(call)
        let range = arguments.first { $0.label == "in" }?.value
        switch (type, name) {
        case ("Int", "random"):
            guard case .range(let lower, let upper, let closed)? = range, let low = lower.integer, let high = upper.integer,
                  closed ? low <= high : low < high
            else { throw fail("Int.random(in:) needs a non-empty range.", call.node) }
            return .int(closed ? Int.random(in: low...high) : Int.random(in: low..<high))
        case ("Double", "random"), ("CGFloat", "random"):
            guard case .range(let lower, let upper, _)? = range, let low = lower.number, let high = upper.number, low <= high else {
                throw fail("Double.random(in:) needs a range.", call.node)
            }
            return .double(Double.random(in: low...high))
        case ("Bool", "random"):
            return .bool(.random())
        case ("Timer", "publish"):
            return .record("Timer", ["interval": arguments.first { $0.label == "every" }?.value ?? .double(1)])
        case ("Color", _), ("Font", _):
            let value = UIValue.member(name, arguments)
            if type == "Color", let color = UIStyles.color(value) { return .color(color) }
            if type == "Font", let font = UIStyles.font(value) { return .font(font) }
        default:
            break
        }
        throw fail("'\(type).\(name)' is not supported.", call.node)
    }

    private func builtinFunction(_ name: String, _ call: UICall) throws -> UIValue? {
        switch name {
        case "send":
            guard let send else {
                throw fail("Messages can be sent once the reply has finished.", call.node)
            }
            let text = try value(call, at: 0)?.text ?? ""
            send(text)
            return .null
        case "withAnimation":
            guard let closure = call.content ?? call.unlabeled(1)?.as(ClosureExprSyntax.self) else { return .null }
            var result = UIValue.null
            var thrown: (any Error)?
            withAnimation {
                do { result = try callClosure(closure, []) } catch { thrown = error }
            }
            if let thrown { throw thrown }
            return result
        case "print":
            return .null
        default:
            break
        }

        let arguments = try evaluate(call)
        let values = arguments.map(\.value)
        let first = values.first ?? .null
        func number(_ index: Int) throws -> Double {
            guard values.indices.contains(index), let number = values[index].number else {
                throw fail("\(name) needs a number.", call.node)
            }
            return number
        }
        func numeric(_ result: Double) -> UIValue {
            values.allSatisfy({ if case .int = $0 { true } else { false } }) && result.isFinite && result == result.rounded()
                ? .int(Int(result)) : .double(result)
        }
        switch name {
        case "min", "max":
            let items = values.count == 1 ? (first.elements ?? values) : values
            guard var best = items.first else { return .null }
            for item in items.dropFirst() where try compare(item, best, call.node) * (name == "min" ? -1 : 1) > 0 {
                best = item
            }
            return best
        case "abs":
            if case .int(let number) = first { return .int(abs(number)) }
            return .double(abs(try number(0)))
        case "round": return numeric((try number(0)).rounded())
        case "floor": return numeric(Foundation.floor(try number(0)))
        case "ceil": return numeric(Foundation.ceil(try number(0)))
        case "sqrt": return .double((try number(0)).squareRoot())
        case "pow": return .double(Foundation.pow(try number(0), try number(1)))
        case "exp": return .double(Foundation.exp(try number(0)))
        case "log": return .double(Foundation.log(try number(0)))
        case "log10": return .double(Foundation.log10(try number(0)))
        case "sin": return .double(Foundation.sin(try number(0)))
        case "cos": return .double(Foundation.cos(try number(0)))
        case "tan": return .double(Foundation.tan(try number(0)))
        case "String":
            if let format = arguments.first(where: { $0.label == "format" })?.value {
                return .string(Self.format(format.text, values.dropFirst().map { $0 }))
            }
            if let repeated = arguments.first(where: { $0.label == "repeating" })?.value,
               let count = arguments.first(where: { $0.label == "count" })?.value.integer {
                return .string(String(repeating: repeated.text, count: max(count, 0)))
            }
            if case .array(let characters) = first {
                return .string(characters.map(\.text).joined())
            }
            return .string(first.text)
        case "Int":
            if case .string(let text) = first { return Int(text.trimmingCharacters(in: .whitespaces)).map(UIValue.int) ?? .null }
            return first.number.map { $0.isFinite ? UIValue.int(Int($0)) : UIValue.null } ?? .null
        case "Double", "Float", "CGFloat":
            if case .string(let text) = first { return Double(text.trimmingCharacters(in: .whitespaces)).map(UIValue.double) ?? .null }
            return first.number.map(UIValue.double) ?? .null
        case "Bool":
            if case .string(let text) = first { return text == "true" ? .bool(true) : text == "false" ? .bool(false) : .null }
            return first
        case "Array":
            if let repeated = arguments.first(where: { $0.label == "repeating" })?.value,
               let count = arguments.first(where: { $0.label == "count" })?.value.integer {
                return .array(Array(repeating: repeated, count: max(count, 0)))
            }
            return .array(first.elements ?? [])
        case "Set":
            var seen: Set<UIValue> = []
            return .array((first.elements ?? []).filter { seen.insert($0).inserted })
        case "UUID": return .string(UUID().uuidString)
        case "Date":
            if let interval = arguments.first(where: { $0.label == "timeIntervalSinceNow" })?.value.number {
                return .date(Date(timeIntervalSinceNow: interval))
            }
            if let interval = arguments.first(where: { $0.label == "timeIntervalSince1970" })?.value.number {
                return .date(Date(timeIntervalSince1970: interval))
            }
            return .date(.now)
        case "URL":
            return arguments.first { $0.label == "string" }?.value ?? .null
        case "zip":
            guard values.count == 2, let left = values[0].elements, let right = values[1].elements else { return .array([]) }
            return .array(zip(left, right).map { .tuple([$0, $1], labels: [nil, nil]) })
        case "stride":
            guard let from = arguments.first(where: { $0.label == "from" })?.value.number,
                  let by = arguments.first(where: { $0.label == "by" })?.value.number, by != 0
            else { throw fail("stride needs `from` and a nonzero `by`.", call.node) }
            let integers = values.allSatisfy { if case .int = $0 { true } else { false } }
            var results: [Double] = []
            if let to = arguments.first(where: { $0.label == "to" })?.value.number {
                results = Array(Swift.stride(from: from, to: to, by: by).prefix(10_000))
            } else if let through = arguments.first(where: { $0.label == "through" })?.value.number {
                results = Array(Swift.stride(from: from, through: through, by: by).prefix(10_000))
            }
            return .array(results.map { integers ? .int(Int($0)) : .double($0) })
        case "CLLocationCoordinate2D":
            return .record("CLLocationCoordinate2D", Dictionary(arguments.compactMap { argument in
                argument.label.map { ($0, argument.value) }
            }, uniquingKeysWith: { $1 }))
        case "GridItem":
            return .record("GridItem", ["size": first, "spacing": arguments.first { $0.label == "spacing" }?.value ?? .null])
        case "Color":
            if let color = UIStyles.color(.member("init", arguments)) { return .color(color) }
            throw fail("Use a named color such as `.blue`, or `Color(red:green:blue:)`.", call.node)
        case "LinearGradient", "RadialGradient", "AngularGradient":
            return .style(UIReference(UIStyles.gradient(name, arguments)))
        default:
            return nil
        }
    }

    // MARK: Methods

    /// Calls a method of a value. A mutating method writes the changed value back through
    /// `baseExpression`.
    private func method(_ base: UIValue, _ name: String, _ call: UICall, _ baseExpression: ExprSyntax) throws -> UIValue {
        if case .record(let type, let fields) = base, let declaration = program.types[type], let method = declaration.methods[name] {
            let instance = UIInstance(type: declaration, fields: fields.mapValues { .value($0) }, value: base)
            let result = try withContext(instance: instance, scopes: [[:]]) {
                try callFunction(method, try evaluate(call))
            }
            let updated = UIValue.record(type, instance.fields.mapValues(\.value))
            if updated != base {
                try assign(baseExpression, updated)
            }
            return result
        }
        if case .enumCase(let type, _) = base, let method = program.types[type]?.methods[name] {
            return try withContext(instance: UIInstance(type: program.types[type], value: base), scopes: [[:]]) {
                try callFunction(method, try evaluate(call))
            }
        }
        if case .member(let memberName, let memberArguments) = base {
            // A chain such as `.blue.opacity(0.5)` or `.title.bold()` stays an implicit member.
            return .member(memberName + "." + name, memberArguments + (try evaluate(call)))
        }
        if case .color(let color) = base, name == "opacity", let opacity = try value(call, at: 0)?.number {
            return .color(color.opacity(opacity))
        }
        if case .font(let font) = base, let modified = UIStyles.font(.member("font." + name, try evaluate(call)), base: font) {
            return .font(modified)
        }
        if case .record("Timer", _) = base {
            return base
        }

        // Closure arguments run in this interpreter so they can read the current scope.
        func closure(at index: Int = 0) throws -> ClosureExprSyntax {
            if let closure = call.trailingClosure ?? call.unlabeled(index)?.as(ClosureExprSyntax.self)
                ?? call.arguments.first(where: { $0.expression.is(ClosureExprSyntax.self) })?.expression.as(ClosureExprSyntax.self) {
                return closure
            }
            throw fail("\(name) needs a closure.", call.node)
        }
        func apply(_ closure: ClosureExprSyntax, _ arguments: UIValue...) throws -> UIValue {
            try callClosure(closure, arguments)
        }
        /// A closure, or an operator such as `<` or `+` passed as a function.
        func comparator() throws -> (UIValue, UIValue) throws -> UIValue {
            if let op = (call.unlabeled(call.unlabeled(1) == nil ? 0 : 1) ?? call.expression("by"))?
                .as(DeclReferenceExprSyntax.self)?.baseName.text, !op.first!.isLetter {
                return { try self.binary(op, $0, $1, call.node) }
            }
            let syntax = try closure(at: 1)
            return { try self.callClosure(syntax, [$0, $1]) }
        }
        func mutate(_ newValue: UIValue, returning result: UIValue = .null) throws -> UIValue {
            try assign(baseExpression, newValue)
            return result
        }

        switch base {
        case .string(let text):
            let first = try value(call, at: 0)
            switch name {
            case "uppercased": return .string(text.uppercased())
            case "lowercased": return .string(text.lowercased())
            case "capitalized": return .string(text.capitalized)
            case "contains": return .bool(text.contains(first?.text ?? ""))
            case "localizedCaseInsensitiveContains": return .bool(text.localizedCaseInsensitiveContains(first?.text ?? ""))
            case "hasPrefix": return .bool(text.hasPrefix(first?.text ?? ""))
            case "hasSuffix": return .bool(text.hasSuffix(first?.text ?? ""))
            case "trimmingCharacters":
                let set: CharacterSet = try value(call, "in")?.memberName == "whitespaces" ? .whitespaces : .whitespacesAndNewlines
                return .string(text.trimmingCharacters(in: set))
            case "split":
                let separator = try value(call, "separator")?.text ?? first?.text ?? " "
                return .array(text.split(separator: separator).map { .string(String($0)) })
            case "components":
                return .array(text.components(separatedBy: try value(call, "separatedBy")?.text ?? " ").map(UIValue.string))
            case "replacingOccurrences":
                return .string(text.replacingOccurrences(of: try value(call, "of")?.text ?? "", with: try value(call, "with")?.text ?? ""))
            case "prefix": return .string(String(text.prefix(first?.integer ?? 0)))
            case "suffix": return .string(String(text.suffix(first?.integer ?? 0)))
            case "dropFirst": return .string(String(text.dropFirst(first?.integer ?? 1)))
            case "dropLast": return .string(String(text.dropLast(first?.integer ?? 1)))
            case "reversed": return .string(String(text.reversed()))
            case "append": return try mutate(.string(text + (first?.text ?? "")))
            case "formatted": return .string(text)
            default: break
            }
        case .int, .double:
            let number = base.number ?? 0
            switch name {
            case "formatted": return .string(Self.formatted(number, style: call.unlabeled(0)?.trimmedDescription ?? ""))
            case "rounded": return .double(number.rounded())
            case "squareRoot": return .double(number.squareRoot())
            case "isMultiple":
                guard case .int(let integer) = base, let divisor = try value(call, "of")?.integer else { break }
                return .bool(integer.isMultiple(of: divisor))
            case "truncatingRemainder":
                return .double(number.truncatingRemainder(dividingBy: try value(call, "dividingBy")?.number ?? 1))
            default: break
            }
        case .bool(let flag):
            if name == "toggle" { return try mutate(.bool(!flag)) }
        case .date(let date):
            switch name {
            case "formatted": return .string(Self.formatted(date, try evaluate(call)))
            case "addingTimeInterval": return .date(date.addingTimeInterval(try value(call, at: 0)?.number ?? 0))
            case "timeIntervalSince":
                guard case .date(let other)? = try value(call, at: 0) else { break }
                return .double(date.timeIntervalSince(other))
            default: break
            }
        case .dictionary(var values):
            switch name {
            case "removeValue":
                let removed = values.removeValue(forKey: try value(call, "forKey") ?? .null) ?? .null
                return try mutate(.dictionary(values), returning: removed)
            case "removeAll": return try mutate(.dictionary([:]))
            case "mapValues":
                let syntax = try closure()
                return .dictionary(try values.mapValues { try apply(syntax, $0) })
            default: break
            }
        case .range(let lower, let upper, let closed) where name == "contains":
            guard let item = try value(call, at: 0) else { break }
            let upperOrder = try compare(item, upper, call.node)
            return .bool(try compare(item, lower, call.node) >= 0 && (closed ? upperOrder <= 0 : upperOrder < 0))
        default:
            break
        }

        guard var values = base.elements else {
            throw fail("Value of type \(base.typeName) has no method '\(name)'.", call.node)
        }
        let isArray = if case .array = base { true } else { false }
        let first = try value(call, at: 0)
        switch name {
        case "append" where isArray:
            if let contents = try value(call, "contentsOf") {
                values += contents.elements ?? []
            } else {
                values.append(first ?? .null)
            }
            return try mutate(.array(values))
        case "insert" where isArray:
            let index = min(max(try value(call, "at")?.integer ?? 0, 0), values.count)
            values.insert(first ?? .null, at: index)
            return try mutate(.array(values))
        case "remove" where isArray:
            guard let index = try value(call, "at")?.integer, values.indices.contains(index) else {
                throw fail("Index is out of range.", call.node)
            }
            let removed = values.remove(at: index)
            return try mutate(.array(values), returning: removed)
        case "removeAll" where isArray:
            if call.trailingClosure != nil || call.expression("where") != nil {
                let syntax = try closure()
                values = try values.filter { try !truth(apply(syntax, $0), call.node) }
            } else {
                values = []
            }
            return try mutate(.array(values))
        case "removeFirst" where isArray, "removeLast" where isArray, "popLast" where isArray:
            guard !values.isEmpty else {
                if name == "popLast" { return .null }
                throw fail("Cannot remove from an empty array.", call.node)
            }
            let removed = name == "removeFirst" ? values.removeFirst() : values.removeLast()
            return try mutate(.array(values), returning: removed)
        case "swapAt" where isArray:
            guard let i = first?.integer, let j = try value(call, at: 1)?.integer, values.indices.contains(i), values.indices.contains(j) else {
                throw fail("Index is out of range.", call.node)
            }
            values.swapAt(i, j)
            return try mutate(.array(values))
        case "sort" where isArray:
            let order = call.arguments.isEmpty && call.trailingClosure == nil ? { try self.binary("<", $0, $1, call.node) } : try comparator()
            return try mutate(.array(try sorted(values, order, call)))
        case "shuffle" where isArray:
            return try mutate(.array(values.shuffled()))
        case "contains":
            if call.trailingClosure != nil || call.expression("where") != nil {
                let syntax = try closure()
                return .bool(try values.contains { try truth(apply(syntax, $0), call.node) })
            }
            return .bool(values.contains { equal($0, first ?? .null) })
        case "allSatisfy":
            let syntax = try closure()
            return .bool(try values.allSatisfy { try truth(apply(syntax, $0), call.node) })
        case "first", "last":
            let syntax = try closure()
            let found = name == "first"
                ? try values.first { try truth(apply(syntax, $0), call.node) }
                : try values.last { try truth(apply(syntax, $0), call.node) }
            return found ?? .null
        case "firstIndex", "lastIndex":
            let index: Int?
            if let item = try value(call, "of") {
                index = name == "firstIndex" ? values.firstIndex { equal($0, item) } : values.lastIndex { equal($0, item) }
            } else {
                let syntax = try closure()
                index = name == "firstIndex"
                    ? try values.firstIndex { try truth(apply(syntax, $0), call.node) }
                    : try values.lastIndex { try truth(apply(syntax, $0), call.node) }
            }
            return index.map(UIValue.int) ?? .null
        case "map":
            if let keyPath = first, case .keyPath(let path) = keyPath {
                return .array(try values.map { try path.reduce($0) { try property($0, $1, call.node) } })
            }
            let syntax = try closure()
            return .array(try values.map { try apply(syntax, $0) })
        case "compactMap":
            let syntax = try closure()
            return .array(try values.map { try apply(syntax, $0) }.filter { $0 != .null })
        case "flatMap":
            let syntax = try closure()
            return .array(try values.flatMap { try apply(syntax, $0).elements ?? [] })
        case "filter":
            let syntax = try closure()
            return .array(try values.filter { try truth(apply(syntax, $0), call.node) })
        case "reduce":
            var result = first ?? .null
            if let op = call.unlabeled(1)?.as(DeclReferenceExprSyntax.self)?.baseName.text, !op.first!.isLetter {
                for item in values { result = try binary(op, result, item, call.node) }
            } else {
                let syntax = try closure(at: 1)
                for item in values { result = try apply(syntax, result, item) }
            }
            return result
        case "forEach":
            let syntax = try closure()
            for item in values { _ = try apply(syntax, item) }
            return .null
        case "sorted":
            let order = call.arguments.isEmpty && call.trailingClosure == nil ? { try self.binary("<", $0, $1, call.node) } : try comparator()
            return .array(try sorted(values, order, call))
        case "reversed": return .array(values.reversed())
        case "shuffled": return .array(values.shuffled())
        case "enumerated": return .array(values.enumerated().map { .tuple([.int($0.offset), $0.element], labels: ["offset", "element"]) })
        case "joined": return .string(values.map(\.text).joined(separator: try value(call, "separator")?.text ?? ""))
        case "prefix": return .array(Array(values.prefix(first?.integer ?? 0)))
        case "suffix": return .array(Array(values.suffix(first?.integer ?? 0)))
        case "dropFirst": return .array(Array(values.dropFirst(first?.integer ?? 1)))
        case "dropLast": return .array(Array(values.dropLast(first?.integer ?? 1)))
        case "randomElement": return values.randomElement() ?? .null
        case "min", "max":
            let order = call.arguments.isEmpty && call.trailingClosure == nil ? { try self.binary("<", $0, $1, call.node) } : try comparator()
            guard var best = values.first else { return .null }
            for item in values.dropFirst() {
                let isLess = try truth(order(item, best), call.node)
                if name == "min" ? isLess : try truth(order(best, item), call.node) { best = item }
            }
            return best
        case "count":
            let syntax = try closure()
            return .int(try values.filter { try truth(apply(syntax, $0), call.node) }.count)
        default:
            throw fail("Value of type \(base.typeName) has no method '\(name)'.", call.node)
        }
    }

    private func sorted(_ values: [UIValue], _ order: (UIValue, UIValue) throws -> UIValue, _ call: UICall) throws -> [UIValue] {
        // Insertion sort keeps errors thrown by the comparator.
        var result: [UIValue] = []
        for value in values {
            var index = result.count
            while index > 0, try truth(order(value, result[index - 1]), call.node) {
                index -= 1
            }
            result.insert(value, at: index)
        }
        return result
    }

    /// `formatted()` for numbers. The format style is read from the argument's source, such
    /// as `.percent`, `.currency(code: "USD")`, or `.number.precision(.fractionLength(2))`.
    static func formatted(_ number: Double, style: String) -> String {
        let digits = style.firstMatch(of: #/fractionLength\((\d+)/#).flatMap { Int($0.1) }
        if style.contains("percent") {
            return number.formatted(.percent.precision(.fractionLength(digits ?? 0)))
        }
        if let code = style.firstMatch(of: #/currency\(code:\s*"(\w+)"/#)?.1 {
            return number.formatted(.currency(code: String(code)))
        }
        if let digits {
            return number.formatted(.number.precision(.fractionLength(digits)))
        }
        return number.formatted()
    }

    static func formatted(_ date: Date, _ arguments: [UIArgument]) -> String {
        guard !arguments.isEmpty else { return date.formatted() }
        let dateStyle: Date.FormatStyle.DateStyle = switch arguments.first(where: { $0.label == "date" })?.value.memberName {
        case "omitted": .omitted
        case "numeric": .numeric
        case "long": .long
        case "complete": .complete
        case nil: arguments.contains { $0.label == "time" } ? .omitted : .abbreviated
        default: .abbreviated
        }
        let timeStyle: Date.FormatStyle.TimeStyle = switch arguments.first(where: { $0.label == "time" })?.value.memberName {
        case "shortened": .shortened
        case "standard": .standard
        case "complete": .complete
        default: .omitted
        }
        return date.formatted(date: dateStyle, time: timeStyle)
    }
}

// MARK: - Operator folding

/// A sequence of operands and operators folded by Swift's precedence.
indirect enum FoldedExpression {
    case operand(ExprSyntax)
    case binary(String, FoldedExpression, FoldedExpression)
    case ternary(FoldedExpression, ExprSyntax, FoldedExpression)
}

/// Folds the flat operand-operator list the parser produces for an expression such as
/// `a + b * c == d ? x : y`, following the standard library's precedence groups.
struct OperatorFolder {
    private var operands: [ExprSyntax] = []
    private var operators: [ExprSyntax] = []
    private var operandIndex = 0
    private var operatorIndex = 0

    init(elements: [ExprSyntax]) {
        var expectsOperand = true
        var skipType = false
        for element in elements {
            if skipType {
                skipType = false
                continue
            }
            if element.is(UnresolvedAsExprSyntax.self) || element.is(UnresolvedIsExprSyntax.self) {
                // Casts keep their operand's value.
                skipType = true
                continue
            }
            if expectsOperand {
                operands.append(element)
            } else {
                operators.append(element)
            }
            expectsOperand.toggle()
        }
    }

    mutating func fold() -> FoldedExpression {
        fold(minimum: 0)
    }

    private mutating func fold(minimum: Int) -> FoldedExpression {
        var lhs = FoldedExpression.operand(operands[min(operandIndex, operands.count - 1)])
        operandIndex += 1
        while operatorIndex < operators.count {
            let element = operators[operatorIndex]
            let (name, precedence, isRightAssociative) = Self.info(element)
            guard precedence >= minimum else { break }
            operatorIndex += 1
            let rhs = fold(minimum: isRightAssociative ? precedence : precedence + 1)
            if let ternary = element.as(UnresolvedTernaryExprSyntax.self) {
                lhs = .ternary(lhs, ternary.thenExpression, rhs)
            } else {
                lhs = .binary(name, lhs, rhs)
            }
        }
        return lhs
    }

    private static func info(_ element: ExprSyntax) -> (String, Int, Bool) {
        if element.is(AssignmentExprSyntax.self) { return ("=", 1, true) }
        if element.is(UnresolvedTernaryExprSyntax.self) { return ("?:", 2, true) }
        let name = element.as(BinaryOperatorExprSyntax.self)?.operator.text ?? ""
        return switch name {
        case "=", "+=", "-=", "*=", "/=", "%=": (name, 1, true)
        case "||": (name, 3, false)
        case "&&": (name, 4, false)
        case "==", "!=", "<", ">", "<=", ">=", "===", "!==": (name, 5, false)
        case "??": (name, 6, true)
        case "..<", "...": (name, 7, false)
        case "+", "-": (name, 8, false)
        case "*", "/", "%": (name, 9, false)
        default: (name, 8, false)
        }
    }
}
