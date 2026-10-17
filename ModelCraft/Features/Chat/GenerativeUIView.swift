//
//  GenerativeUIView.swift
//  ModelCraft
//
//  Created by Hongshen on 10/10/26.
//

import SwiftUI
import Charts
import MapKit
import SwiftSyntax

/// Shows a `ui` block: SwiftUI code that the interpreter runs to build native views.
struct GenerativeUIView: View {

    let source: String
    /// Sends text as the user's next message; `nil` while the reply is generating.
    let send: ((String) -> Void)?

    @State private var runtime = GenerativeUIRuntime()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch Result(catching: { try GenerativeUIProgram(source: source) }) {
            case .success(let program):
                InterpretedView(program: program, runtime: runtime, send: send)
            case .failure(let error):
                GenerativeUIErrorView(error: GenerativeUIError(error), send: send)
            }
            if let error = runtime.actionError {
                GenerativeUIErrorView(error: error, send: send)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

/// State shared by all views of one block: the last error thrown by a button or other action.
@Observable
final class GenerativeUIRuntime {
    var actionError: GenerativeUIError?
}

extension GenerativeUIError {
    init(_ error: any Error) {
        self = error as? GenerativeUIError ?? GenerativeUIError(message: error.localizedDescription, line: nil)
    }
}

/// One instance of a view type declared in a block, or the block's top-level views.
/// SwiftUI keeps its `@State` values with the view's identity, as for a compiled view.
struct InterpretedView: View {

    let program: GenerativeUIProgram
    let type: UITypeDecl?
    let runtime: GenerativeUIRuntime?
    let send: ((String) -> Void)?
    private let fields: [String: UIVariable]
    private let initError: GenerativeUIError?

    @State private var store: UIStateStore

    /// The block's root view.
    init(program: GenerativeUIProgram, runtime: GenerativeUIRuntime?, send: ((String) -> Void)?) {
        self.init(program: program, type: program.rootType.flatMap { program.types[$0] }, arguments: [], runtime: runtime, send: send)
    }

    init(program: GenerativeUIProgram, type: UITypeDecl?, arguments: [UIArgument], runtime: GenerativeUIRuntime?, send: ((String) -> Void)?) {
        self.program = program
        self.type = type
        self.runtime = runtime
        self.send = send
        var fields: [String: UIVariable] = [:]
        var state: [String: UIValue] = [:]
        var initError: GenerativeUIError?
        if let type {
            do {
                let interpreter = UIInterpreter(program: program, instance: UIInstance(), runtime: runtime, send: send)
                let stored = try interpreter.storedFields(of: type, arguments, nil)
                for property in type.storedProperties {
                    if property.wrapper == .state {
                        state[property.name] = stored[property.name]?.value ?? .null
                    } else {
                        fields[property.name] = stored[property.name]
                    }
                }
            } catch {
                initError = GenerativeUIError(error)
            }
        }
        self.fields = fields
        self.initError = initError
        _store = State(initialValue: UIStateStore(values: state))
    }

    var body: some View {
        switch Result(catching: { try render() }) {
        case .success(let view):
            view
        case .failure(let error):
            GenerativeUIErrorView(error: GenerativeUIError(error), send: send)
        }
    }

    private func render() throws -> AnyView {
        if let initError {
            throw initError
        }
        let interpreter = UIInterpreter(
            program: program,
            instance: UIInstance(type: type, fields: fields, store: store),
            runtime: runtime,
            send: send)
        if let type {
            guard let body = type.properties.first(where: { $0.name == "body" })?.getter else {
                throw GenerativeUIError(message: "\(type.name) has no `body`.", line: nil)
            }
            return try interpreter.anyView(interpreter.builderValue(body), body)
        }
        let views = try interpreter.build(program.rootStatements)
            .map { try interpreter.anyView($0, program.rootStatements[0]) }
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            UIChildren(views: views)
        })
    }
}

/// Shows why a block or action failed, and lets the user ask the model to fix it.
struct GenerativeUIErrorView: View {

    let error: GenerativeUIError
    let send: ((String) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("This interface couldn't be shown")
                    .font(.headline)
                Text(verbatim: error.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let send {
                    Button("Ask to Fix") {
                        send(String(localized: "The `ui` block failed: \(error.description). Rewrite it with the supported SwiftUI subset."))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct UIChildren: View {
    let views: [AnyView]

    var body: some View {
        ForEach(views.indices, id: \.self) { index in
            views[index]
        }
    }
}

struct UIIdentified: Identifiable {
    let id: UIValue
    let view: AnyView
}

/// The content of a `ForEach`. Elements are identified by their `UIValue` ids, which also
/// tag them for a `Picker` whose selection is a `UIValue` binding.
struct UIEach: View {
    let items: [UIIdentified]

    var body: some View {
        ForEach(items) { item in
            item.view
        }
    }
}

// MARK: - Building views

extension UIInterpreter {

    /// Runs the statements of a view body, `ViewBuilder` closure, or chart content,
    /// returning one value per view. `let` declarations are allowed between views.
    func build(_ items: some Sequence<CodeBlockItemSyntax>) throws -> [UIValue] {
        try withScope {
            var values: [UIValue] = []
            for item in items {
                switch item.item {
                case .decl(let decl):
                    guard let variable = decl.as(VariableDeclSyntax.self) else {
                        throw fail("Only `let` and `var` can be declared in a view body.", decl)
                    }
                    try declare(variable)
                case .expr(let expression):
                    values.append(try buildExpression(expression))
                case .stmt(let statement):
                    if let expression = statement.as(ExpressionStmtSyntax.self) {
                        values.append(try buildExpression(expression.expression))
                    } else if let returnStatement = statement.as(ReturnStmtSyntax.self) {
                        if let expression = returnStatement.expression {
                            values.append(try buildExpression(expression))
                        }
                        return values
                    } else {
                        throw fail("A view body can contain only views, `if`, `switch`, and `let`.", statement)
                    }
                }
            }
            return values
        }
    }

    private func buildExpression(_ expression: ExprSyntax) throws -> UIValue {
        if let ifExpression = expression.as(IfExprSyntax.self) {
            return try withScope {
                if try conditions(ifExpression.conditions) {
                    return .group(try build(ifExpression.body.statements))
                }
                switch ifExpression.elseBody {
                case .ifExpr(let next): return try buildExpression(ExprSyntax(next))
                case .codeBlock(let block): return .group(try build(block.statements))
                case nil: return .group([])
                }
            }
        }
        if let switchExpression = expression.as(SwitchExprSyntax.self) {
            return .group(try withMatchingCase(switchExpression) { try build($0) } ?? [])
        }
        return try eval(expression)
    }

    /// The value of a view body: its only view, or all its views as a group.
    func builderValue(_ items: CodeBlockItemListSyntax) throws -> UIValue {
        let values = try build(items)
        return values.count == 1 ? values[0] : .group(values)
    }

    func buildClosure(_ closure: ClosureExprSyntax?, _ arguments: [UIValue] = []) throws -> [UIValue] {
        guard let closure else { return [] }
        return try withScope(parameters(of: closure, arguments)) {
            try build(closure.statements)
        }
    }

    /// The views of a content closure, laid out by the container they are placed in.
    func content(_ closure: ClosureExprSyntax?) throws -> AnyView {
        guard let closure else { return AnyView(EmptyView()) }
        return try anyView(.group(try buildClosure(closure)), closure)
    }

    func anyView(_ value: UIValue, _ node: some SyntaxProtocol) throws -> AnyView {
        switch value {
        case .view(let view):
            return view.value
        case .group(let values):
            return AnyView(UIChildren(views: try values.map { try anyView($0, node) }))
        case .each(let ids, let values):
            return AnyView(UIEach(items: try zip(ids, values).map { UIIdentified(id: $0, view: try anyView($1, node)) }))
        case .color(let color):
            return AnyView(color)
        case .style(let style):
            return AnyView(Rectangle().fill(style.value))
        case .string(let text):
            return AnyView(Text(text))
        case .null:
            return AnyView(EmptyView())
        case .record("Image", let fields):
            let image = Image(systemName: fields["systemName"]?.text ?? "questionmark")
            guard fields["resizable"] == .bool(true) else { return AnyView(image) }
            let mode: ContentMode = fields["contentMode"]?.memberName == "fill" ? .fill : .fit
            return AnyView(image.resizable().aspectRatio(contentMode: mode))
        default:
            if let shape = UIStyles.shape(value) {
                return AnyView(shape)
            }
            throw fail("Expected a view, found \(value.typeName).", node)
        }
    }

    /// An action that runs a closure or function later, with the variables it captured now.
    /// An error is shown under the block.
    func action(_ expression: ExprSyntax?) -> () -> Void {
        guard let expression else { return {} }
        let closure: UIClosure? = if let syntax = expression.as(ClosureExprSyntax.self) {
            UIClosure(body: .closure(syntax), scopes: scopes, instance: instance)
        } else if case .closure(let closure)? = try? eval(expression) {
            closure
        } else {
            nil
        }
        let program = program, runtime = runtime, send = send
        return {
            guard let closure else { return }
            let interpreter = UIInterpreter(program: program, instance: closure.instance, runtime: runtime, send: send)
            do {
                _ = try interpreter.invoke(closure, [])
                if runtime?.actionError != nil { runtime?.actionError = nil }
            } catch {
                runtime?.actionError = GenerativeUIError(error)
            }
        }
    }

    private func binding(_ call: UICall, _ label: String) throws -> UIBinding {
        guard case .binding(let binding)? = try value(call, label) else {
            throw fail("`\(label):` needs a `$` binding to a @State property.", call.node)
        }
        return binding
    }

    private func text(_ call: UICall) throws -> String? {
        guard let expression = call.unlabeled(0), !expression.is(ClosureExprSyntax.self) else { return nil }
        return try eval(expression).text
    }

    private func range(_ value: UIValue?) -> ClosedRange<Double>? {
        guard case .range(let lower, let upper, _)? = value, let low = lower.number, let high = upper.number else { return nil }
        return low...max(high, low + .ulpOfOne)
    }

    /// Builds a SwiftUI view, shape, chart mark, or map marker named `name`; `nil` for
    /// other names.
    func makeView(_ name: String, _ call: UICall) throws -> UIValue? {
        switch name {
        case "Text":
            if let verbatim = try value(call, "verbatim") {
                return .view(Text(verbatim: verbatim.text))
            }
            guard let expression = call.unlabeled(0) else { return .view(Text(verbatim: "")) }
            let value = try eval(expression)
            if case .date(let date) = value {
                let style: Text.DateStyle = switch try self.value(call, "style")?.memberName {
                case "time": .time
                case "relative": .relative
                case "offset": .offset
                case "timer": .timer
                default: .date
                }
                return .view(Text(date, style: style))
            }
            if let format = call.expression("format"), let number = value.number {
                return .view(Text(verbatim: Self.formatted(number, style: format.trimmedDescription)))
            }
            return expression.is(StringLiteralExprSyntax.self)
                ? .view(Text(UIStyles.markdown(value.text))) : .view(Text(verbatim: value.text))
        case "Label":
            if let title = try text(call) {
                let icon = try value(call, "systemImage")?.text ?? ""
                return .view(Label(title, systemImage: icon))
            }
            let title = try content(call.content ?? call.closure("title"))
            let icon = try content(call.closure("icon"))
            return .view(Label { title } icon: { icon })
        case "Image":
            guard let symbol = try value(call, "systemName") else {
                throw fail("Only `Image(systemName:)` is supported; the block has no image assets.", call.node)
            }
            return .record("Image", ["systemName": symbol])
        case "Button":
            let title = try text(call)
            let actionExpression: ExprSyntax?
            let labelClosure: ClosureExprSyntax?
            if let action = call.expression("action") {
                actionExpression = action
                labelClosure = call.trailingClosure ?? call.closure("label")
            } else {
                actionExpression = call.trailingClosure.map(ExprSyntax.init)
                labelClosure = call.closure("label")
            }
            let perform = action(actionExpression)
            let role: ButtonRole? = switch try value(call, "role")?.memberName {
            case "destructive": .destructive
            case "cancel": .cancel
            default: nil
            }
            if let title {
                return .view(Button(title, role: role, action: perform))
            }
            let label = try content(labelClosure)
            return .view(Button(role: role, action: perform) { label })
        case "Toggle":
            let isOn = try binding(call, "isOn").bool
            if let title = try text(call) {
                return .view(Toggle(title, isOn: isOn))
            }
            let label = try content(call.content)
            return .view(Toggle(isOn: isOn) { label })
        case "Slider":
            let value = try binding(call, "value").double
            let bounds = range(try self.value(call, "in")) ?? 0...1
            let label = try content(call.content ?? call.closure("label"))
            if let step = try self.value(call, "step")?.number, step > 0 {
                return .view(Slider(value: value, in: bounds, step: step) { label })
            }
            return .view(Slider(value: value, in: bounds) { label })
        case "Stepper":
            let label = try text(call).map { AnyView(Text($0)) } ?? content(call.content ?? call.closure("label"))
            if call.expression("onIncrement") != nil {
                let increment = action(call.expression("onIncrement"))
                let decrement = action(call.expression("onDecrement"))
                return .view(Stepper(onIncrement: increment, onDecrement: decrement) { label })
            }
            let value = try binding(call, "value").double
            let step = try self.value(call, "step")?.number ?? 1
            if let bounds = range(try self.value(call, "in")) {
                return .view(Stepper(value: value, in: bounds, step: step) { label })
            }
            return .view(Stepper(value: value, step: step) { label })
        case "TextField", "SecureField":
            let title = try text(call) ?? ""
            let text = try binding(call, "text").string
            if name == "SecureField" {
                return .view(SecureField(title, text: text))
            }
            let axis: Axis = try value(call, "axis")?.memberName == "vertical" ? .vertical : .horizontal
            return .view(TextField(title, text: text, axis: axis))
        case "TextEditor":
            return .view(TextEditor(text: try binding(call, "text").string).frame(minHeight: 80))
        case "Picker":
            let selection = try binding(call, "selection").value
            let options = try content(call.content)
            let title = try text(call) ?? ""
            let label = try call.closure("label").map { try content($0) } ?? AnyView(Text(title))
            return .view(Picker(selection: selection) { options } label: { label })
        case "DatePicker":
            let selection = try binding(call, "selection").date
            let components: DatePickerComponents = switch try value(call, "displayedComponents") {
            case .member("hourAndMinute", _)?: .hourAndMinute
            case .array(let values)? where values.count > 1: [.date, .hourAndMinute]
            case .array(let values)? where values.first?.memberName == "hourAndMinute": .hourAndMinute
            default: .date
            }
            return .view(DatePicker(try text(call) ?? "", selection: selection, displayedComponents: components))
        case "ColorPicker":
            return .view(ColorPicker(try text(call) ?? "", selection: try binding(call, "selection").color))
        case "ProgressView":
            let label = try text(call)
            guard let progress = try value(call, "value")?.number else {
                return .view(ProgressView { if let label { Text(label) } }.controlSize(.small))
            }
            let total = max(try value(call, "total")?.number ?? 1, .ulpOfOne)
            return .view(ProgressView(value: min(max(progress, 0), total), total: total) {
                if let label { Text(label) }
            })
        case "Gauge":
            let bounds = range(try value(call, "in")) ?? 0...1
            let current = min(max(try value(call, "value")?.number ?? bounds.lowerBound, bounds.lowerBound), bounds.upperBound)
            let label = try content(call.content ?? call.closure("label"))
            let currentLabel = try content(call.closure("currentValueLabel"))
            return .view(Gauge(value: current, in: bounds) { label } currentValueLabel: { currentLabel })
        case "Link":
            guard let url = URL(string: try value(call, "destination")?.text ?? "") else {
                throw fail("Link needs a valid `destination` URL.", call.node)
            }
            if let title = try text(call) {
                return .view(Link(title, destination: url))
            }
            let label = try content(call.content)
            return .view(Link(destination: url) { label })
        case "Divider":
            return .view(Divider())
        case "Spacer":
            return .view(Spacer(minLength: try value(call, "minLength")?.number.map { CGFloat($0) }))
        case "EmptyView":
            return .view(EmptyView())
        case "VStack", "LazyVStack":
            let alignment = UIStyles.horizontalAlignment(try value(call, "alignment")) ?? .center
            let spacing = try value(call, "spacing")?.number.map { CGFloat($0) }
            let body = try content(call.content)
            return .view(VStack(alignment: alignment, spacing: spacing) { body })
        case "HStack", "LazyHStack":
            let alignment = UIStyles.verticalAlignment(try value(call, "alignment")) ?? .center
            let spacing = try value(call, "spacing")?.number.map { CGFloat($0) }
            let body = try content(call.content)
            return .view(HStack(alignment: alignment, spacing: spacing) { body })
        case "ZStack":
            let alignment = UIStyles.alignment(try value(call, "alignment")) ?? .center
            let body = try content(call.content)
            return .view(ZStack(alignment: alignment) { body })
        case "Group", "NavigationStack", "NavigationView":
            return .view(try content(call.content))
        case "ScrollView":
            if try value(call, at: 0)?.memberName == "horizontal" {
                let body = try content(call.content)
                return .view(ScrollView(.horizontal) { body })
            }
            // The chat already scrolls, so vertical content is laid out in place.
            let body = try content(call.content)
            return .view(VStack(spacing: nil) { body })
        case "Grid":
            let alignment = UIStyles.alignment(try value(call, "alignment")) ?? .center
            let horizontal = try value(call, "horizontalSpacing")?.number.map { CGFloat($0) }
            let vertical = try value(call, "verticalSpacing")?.number.map { CGFloat($0) }
            let body = try content(call.content)
            return .view(Grid(alignment: alignment, horizontalSpacing: horizontal, verticalSpacing: vertical) { body })
        case "GridRow":
            let body = try content(call.content)
            return .view(GridRow { body })
        case "LazyVGrid", "LazyHGrid":
            let items = try (value(call, "columns") ?? value(call, "rows"))?.elements?.map(UIStyles.gridItem) ?? [GridItem(.flexible())]
            let spacing = try value(call, "spacing")?.number.map { CGFloat($0) }
            if name == "LazyHGrid" {
                let body = try content(call.content)
                return .view(LazyHGrid(rows: items, spacing: spacing) { body })
            }
            let alignment = UIStyles.horizontalAlignment(try value(call, "alignment")) ?? .center
            let body = try content(call.content)
            return .view(LazyVGrid(columns: items, alignment: alignment, spacing: spacing) { body })
        case "Form", "List":
            // Forms and lists are laid out in place, since the chat already scrolls.
            let rows = try anyView(call.unlabeled(0) != nil ? forEach(call) : .group(buildClosure(call.content)), call.node)
            return .view(VStack(alignment: .leading, spacing: 10) { rows })
        case "Section":
            let header: AnyView? = if let title = try text(call) {
                AnyView(Text(title).font(.headline))
            } else {
                try call.closure("header").map { try content($0) }
            }
            let footer: AnyView? = if let title = try value(call, "footer") {
                AnyView(Text(title.text).font(.caption).foregroundStyle(.secondary))
            } else {
                try call.closure("footer").map { try content($0) }
            }
            let body = try content(call.content)
            return .view(VStack(alignment: .leading, spacing: 8) {
                if let header { header }
                body
                if let footer { footer }
            })
        case "GroupBox":
            let body = try content(call.content)
            let label = try text(call).map { AnyView(Text($0)) } ?? content(call.closure("label"))
            return .view(GroupBox {
                VStack(alignment: .leading, spacing: 8) { body }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                label
            })
        case "DisclosureGroup":
            let body = try content(call.content)
            let label = try text(call).map { AnyView(Text($0)) } ?? content(call.closure("label"))
            if case .binding(let expanded)? = try value(call, "isExpanded") {
                return .view(DisclosureGroup(isExpanded: expanded.bool) { body } label: { label })
            }
            return .view(DisclosureGroup { body } label: { label })
        case "Menu":
            let body = try content(call.content)
            let label = try text(call).map { AnyView(Text($0)) } ?? content(call.closure("label"))
            return .view(Menu { body } label: { label })
        case "LabeledContent":
            let title = try text(call) ?? ""
            if let value = try value(call, "value") {
                return .view(LabeledContent(title) { Text(value.text).textSelection(.enabled) })
            }
            let body = try content(call.content)
            return .view(LabeledContent(title) { body })
        case "ContentUnavailableView":
            let title = try text(call) ?? ""
            let icon = try value(call, "systemImage")?.text ?? "questionmark"
            let description = try value(call, "description").map { try anyView($0, call.node) }
            return .view(ContentUnavailableView { Label(title, systemImage: icon) } description: { description })
        case "ForEach":
            return try forEach(call)
        case "Chart":
            return try chart(call)
        case "Map":
            return try map(call)
        case "Card":
            let body = try content(call.content)
            return .view(UICard(title: try text(call), icon: try value(call, "systemImage")?.text) { body })
        case "Stat":
            return .view(UIStat(
                label: try text(call) ?? "",
                value: try value(call, "value")?.text ?? "",
                detail: try value(call, "detail")?.text,
                trend: try value(call, "trend")?.memberName,
                icon: try value(call, "systemImage")?.text))
        case "Callout":
            return .view(UICallout(
                kind: try value(call, "kind")?.memberName,
                title: try value(call, "title")?.text,
                text: try text(call) ?? ""))
        case "Rectangle", "Circle", "Capsule", "Ellipse", "RoundedRectangle",
             "BarMark", "LineMark", "AreaMark", "PointMark", "RuleMark", "SectorMark":
            var fields: [String: UIValue] = [:]
            for argument in call.arguments {
                fields[argument.label ?? "_"] = try eval(argument.expression)
            }
            return .record(name, fields)
        case "Marker":
            return .record("Marker", [
                "title": try value(call, at: 0) ?? .string(""),
                "coordinate": try value(call, "coordinate") ?? .null,
                "systemImage": try value(call, "systemImage") ?? .null,
            ])
        case "TabView":
            throw fail("TabView is not supported. Use a segmented Picker and a switch.", call.node)
        default:
            return nil
        }
    }

    func forEach(_ call: UICall) throws -> UIValue {
        guard let dataExpression = call.unlabeled(0) ?? call.expression("data") else {
            throw fail("ForEach needs a collection.", call.node)
        }
        let data = try eval(dataExpression)
        let elements: [UIValue]
        if case .binding(let binding) = data {
            elements = (0..<(binding.get().elements?.count ?? 0)).map { .binding(binding.element($0)) }
        } else if let values = data.elements {
            elements = values
        } else {
            throw fail("Cannot loop over a value of type \(data.typeName).", dataExpression)
        }
        let keyPath = try value(call, "id")
        let closure = call.content
        var ids: [UIValue] = []
        var items: [UIValue] = []
        for element in elements {
            let plain = if case .binding(let binding) = element { binding.get() } else { element }
            ids.append(try identifier(of: plain, keyPath, call.node))
            let views = try buildClosure(closure, [element])
            items.append(views.count == 1 ? views[0] : .group(views))
        }
        return .each(ids: ids, items: items)
    }

    /// The `id:` key path's value, else an `id` property, else the element itself.
    private func identifier(of element: UIValue, _ keyPath: UIValue?, _ node: Syntax) throws -> UIValue {
        if case .keyPath(let path)? = keyPath {
            return try path.filter { $0 != "self" }.reduce(element) { try property($0, $1, node) }
        }
        switch element {
        case .record, .enumCase:
            return (try? property(element, "id", node)) ?? element
        default:
            return element
        }
    }

    /// Expands groups and `ForEach` content into their values, for charts and maps.
    private func flatten(_ values: [UIValue]) -> [UIValue] {
        values.flatMap { value -> [UIValue] in
            switch value {
            case .group(let values), .each(_, let values): flatten(values)
            default: [value]
            }
        }
    }

    private func chart(_ call: UICall) throws -> UIValue {
        var values: [UIValue] = []
        if let dataExpression = call.unlabeled(0) {
            let data = try eval(dataExpression)
            for element in data.elements ?? [] {
                values += try buildClosure(call.content, [element])
            }
        } else {
            values = try buildClosure(call.content)
        }
        let marks = flatten(values).compactMap(UIChartMark.init)
        return .view(UIChart(marks: marks))
    }

    private func map(_ call: UICall) throws -> UIValue {
        let markers = flatten(try buildClosure(call.content)).compactMap { value -> UIMapMarker? in
            guard case .record("Marker", let fields) = value,
                  let latitude = fields["coordinate"]?.field("latitude")?.number,
                  let longitude = fields["coordinate"]?.field("longitude")?.number
            else { return nil }
            return UIMapMarker(
                title: fields["title"]?.text ?? "",
                systemImage: fields["systemImage"].flatMap { $0 == .null ? nil : $0.text },
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        return .view(UIMap(markers: markers))
    }

    // MARK: Modifiers

    /// Applies a modifier to a view, shape, chart mark, or image; `nil` when `base` is a
    /// value whose methods are not modifiers. Unknown view modifiers leave the view as it is.
    func modify(_ base: UIValue, _ name: String, _ call: UICall) throws -> UIValue? {
        switch base {
        case .record(let type, var fields) where type.hasSuffix("Mark"):
            switch name {
            case "foregroundStyle":
                if let series = try value(call, "by") {
                    fields["series"] = series
                } else {
                    fields["color"] = try value(call, at: 0)
                }
            default:
                break
            }
            return .record(type, fields)
        case .record("Image", var fields) where ["resizable", "aspectRatio", "scaledToFit", "scaledToFill"].contains(name):
            fields["resizable"] = .bool(true)
            if name == "scaledToFill" { fields["contentMode"] = .member("fill", []) }
            if name == "aspectRatio", let mode = try value(call, "contentMode") { fields["contentMode"] = mode }
            return .record("Image", fields)
        case .record("Image", _):
            break
        case .record:
            guard let shape = UIStyles.shape(base) else { return nil }
            switch name {
            case "fill":
                let style = UIStyles.style(try value(call, at: 0)) ?? AnyShapeStyle(.foreground)
                return .view(shape.fill(style))
            case "stroke", "strokeBorder":
                let style = UIStyles.style(try value(call, at: 0)) ?? AnyShapeStyle(.foreground)
                let width = CGFloat(try value(call, "lineWidth")?.number ?? 1)
                return .view(shape.stroke(style, lineWidth: width))
            default:
                break
            }
        case .view, .group, .each:
            break
        case .color where name != "opacity":
            break
        default:
            return nil
        }
        return .view(try applyModifier(try anyView(base, call.node), name, call))
    }

    private func applyModifier(_ view: AnyView, _ name: String, _ call: UICall) throws -> AnyView {
        let first = try value(call, at: 0)
        func number(_ label: String) throws -> CGFloat? {
            try value(call, label)?.number.map { CGFloat($0) }
        }
        switch name {
        case "padding":
            if let amount = first?.number {
                return AnyView(view.padding(amount))
            }
            if let first, let edges = UIStyles.edges(first) {
                if let amount = try value(call, at: 1)?.number {
                    return AnyView(view.padding(edges, amount))
                }
                return AnyView(view.padding(edges))
            }
            return AnyView(view.padding())
        case "font":
            return AnyView(view.font(first.flatMap { UIStyles.font($0) }))
        case "fontWeight":
            return AnyView(view.fontWeight(first.flatMap(UIStyles.weight)))
        case "fontDesign":
            return AnyView(view.fontDesign(first.flatMap(UIStyles.design)))
        case "bold":
            return AnyView(view.bold(first != .bool(false)))
        case "italic":
            return AnyView(view.italic(first != .bool(false)))
        case "monospaced":
            return AnyView(view.monospaced(first != .bool(false)))
        case "monospacedDigit":
            return AnyView(view.monospacedDigit())
        case "strikethrough":
            return AnyView(view.strikethrough(first != .bool(false)))
        case "underline":
            return AnyView(view.underline(first != .bool(false)))
        case "foregroundStyle", "foregroundColor":
            guard let style = UIStyles.style(first) else { return view }
            return AnyView(view.foregroundStyle(style))
        case "tint":
            return AnyView(view.tint(UIStyles.style(first)))
        case "background", "overlay":
            let alignment = UIStyles.alignment(try value(call, "alignment")) ?? .center
            let layer: AnyView
            if let closure = call.content {
                layer = try content(closure)
            } else if let first, let style = UIStyles.style(first) {
                if let shape = UIStyles.shape(try value(call, "in")) {
                    layer = AnyView(shape.fill(style))
                } else {
                    layer = AnyView(Rectangle().fill(style))
                }
            } else if let first {
                layer = try anyView(first, call.node)
            } else {
                return view
            }
            return name == "background"
                ? AnyView(view.background(alignment: alignment) { layer })
                : AnyView(view.overlay(alignment: alignment) { layer })
        case "border":
            let style = UIStyles.style(first) ?? AnyShapeStyle(.separator)
            return AnyView(view.border(style, width: try number("width") ?? 1))
        case "frame":
            let alignment = UIStyles.alignment(try value(call, "alignment")) ?? .center
            let flexible = ["minWidth", "idealWidth", "maxWidth", "minHeight", "idealHeight", "maxHeight"]
            if call.arguments.contains(where: { flexible.contains($0.label ?? "") }) {
                return AnyView(view.frame(
                    minWidth: try number("minWidth"), idealWidth: try number("idealWidth"), maxWidth: try number("maxWidth"),
                    minHeight: try number("minHeight"), idealHeight: try number("idealHeight"), maxHeight: try number("maxHeight"),
                    alignment: alignment))
            }
            return AnyView(view.frame(width: try number("width"), height: try number("height"), alignment: alignment))
        case "cornerRadius":
            return AnyView(view.clipShape(RoundedRectangle(cornerRadius: CGFloat(first?.number ?? 0))))
        case "clipShape":
            guard let shape = UIStyles.shape(first) else { return view }
            return AnyView(view.clipShape(shape))
        case "opacity":
            return AnyView(view.opacity(first?.number ?? 1))
        case "shadow":
            let color = UIStyles.color(try value(call, "color") ?? .null) ?? Color.black.opacity(0.2)
            return AnyView(view.shadow(color: color, radius: try number("radius") ?? 4, x: try number("x") ?? 0, y: try number("y") ?? 0))
        case "multilineTextAlignment":
            let alignment: TextAlignment = switch first?.memberName {
            case "center": .center
            case "trailing": .trailing
            default: .leading
            }
            return AnyView(view.multilineTextAlignment(alignment))
        case "lineLimit":
            return AnyView(view.lineLimit(first?.integer))
        case "lineSpacing":
            return AnyView(view.lineSpacing(CGFloat(first?.number ?? 0)))
        case "disabled":
            return AnyView(view.disabled(first == .bool(true)))
        case "buttonStyle":
            switch first?.memberName {
            case "borderedProminent": return AnyView(view.buttonStyle(.borderedProminent))
            case "bordered": return AnyView(view.buttonStyle(.bordered))
            case "borderless": return AnyView(view.buttonStyle(.borderless))
            case "plain": return AnyView(view.buttonStyle(.plain))
            case "link": return AnyView(view.buttonStyle(.link))
            default: return view
            }
        case "pickerStyle":
            switch first?.memberName {
            case "segmented": return AnyView(view.pickerStyle(.segmented))
            case "menu": return AnyView(view.pickerStyle(.menu))
            case "radioGroup": return AnyView(view.pickerStyle(.radioGroup))
            case "inline": return AnyView(view.pickerStyle(.inline))
            case "palette": return AnyView(view.pickerStyle(.palette))
            default: return view
            }
        case "toggleStyle":
            switch first?.memberName {
            case "switch": return AnyView(view.toggleStyle(.switch))
            case "checkbox": return AnyView(view.toggleStyle(.checkbox))
            case "button": return AnyView(view.toggleStyle(.button))
            default: return view
            }
        case "textFieldStyle":
            switch first?.memberName {
            case "roundedBorder": return AnyView(view.textFieldStyle(.roundedBorder))
            case "plain": return AnyView(view.textFieldStyle(.plain))
            case "squareBorder": return AnyView(view.textFieldStyle(.squareBorder))
            default: return view
            }
        case "controlSize":
            let size: ControlSize = switch first?.memberName {
            case "mini": .mini
            case "small": .small
            case "large": .large
            case "extraLarge": .extraLarge
            default: .regular
            }
            return AnyView(view.controlSize(size))
        case "labelsHidden":
            return AnyView(view.labelsHidden())
        case "tag":
            return AnyView(view.tag(first ?? .null))
        case "onTapGesture":
            let perform = action(call.content.map(ExprSyntax.init) ?? call.expression("perform"))
            return AnyView(view.onTapGesture(count: try value(call, "count")?.integer ?? 1, perform: perform))
        case "onAppear":
            let perform = action(call.content.map(ExprSyntax.init) ?? call.expression("perform"))
            return AnyView(view.onAppear(perform: perform))
        case "onChange":
            let perform = action(call.content.map(ExprSyntax.init))
            return AnyView(view.onChange(of: try value(call, "of") ?? .null) { perform() })
        case "onReceive":
            guard case .record("Timer", let fields)? = first, let interval = fields["interval"]?.number else { return view }
            let perform = action(call.content.map(ExprSyntax.init) ?? call.expression("perform"))
            return AnyView(view.task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(max(interval, 0.05)))
                    await MainActor.run { perform() }
                }
            })
        case "help":
            return AnyView(view.help(first?.text ?? ""))
        case "accessibilityLabel":
            return AnyView(view.accessibilityLabel(first?.text ?? ""))
        case "fixedSize":
            if call.arguments.isEmpty {
                return AnyView(view.fixedSize())
            }
            return AnyView(view.fixedSize(
                horizontal: try value(call, "horizontal") == .bool(true),
                vertical: try value(call, "vertical") == .bool(true)))
        case "layoutPriority":
            return AnyView(view.layoutPriority(first?.number ?? 0))
        case "offset":
            return AnyView(view.offset(x: try number("x") ?? 0, y: try number("y") ?? 0))
        case "rotationEffect":
            return AnyView(view.rotationEffect(UIStyles.angle(first)))
        case "scaleEffect":
            return AnyView(view.scaleEffect(CGFloat(first?.number ?? 1)))
        case "animation":
            return AnyView(view.animation(UIStyles.animation(first), value: try value(call, "value") ?? .null))
        case "textSelection":
            return AnyView(view.textSelection(.enabled))
        case "imageScale":
            let scale: Image.Scale = switch first?.memberName {
            case "small": .small
            case "large": .large
            default: .medium
            }
            return AnyView(view.imageScale(scale))
        case "symbolRenderingMode":
            let mode: SymbolRenderingMode? = switch first?.memberName {
            case "hierarchical": .hierarchical
            case "multicolor": .multicolor
            case "palette": .palette
            case "monochrome": .monochrome
            default: nil
            }
            return AnyView(view.symbolRenderingMode(mode))
        case "chartXAxisLabel":
            return AnyView(view.chartXAxisLabel(first?.text ?? ""))
        case "chartYAxisLabel":
            return AnyView(view.chartYAxisLabel(first?.text ?? ""))
        case "chartLegend":
            let visibility: Visibility = switch first?.memberName {
            case "hidden": .hidden
            case "visible": .visible
            default: .automatic
            }
            return AnyView(view.chartLegend(visibility))
        default:
            return view
        }
    }
}

// MARK: - Typed bindings

extension UIBinding {
    var bool: Binding<Bool> {
        Binding(get: { self.get() == .bool(true) }, set: { self.set(.bool($0)) })
    }

    /// Keeps an `Int` property an `Int` when a slider or stepper changes it.
    var double: Binding<Double> {
        Binding(
            get: { self.get().number ?? 0 },
            set: { newValue in
                if case .int = self.get() {
                    self.set(.int(Int(newValue.rounded())))
                } else {
                    self.set(.double(newValue))
                }
            })
    }

    var string: Binding<String> {
        Binding(get: { self.get() == .null ? "" : self.get().text }, set: { self.set(.string($0)) })
    }

    var date: Binding<Date> {
        Binding(
            get: { if case .date(let date) = self.get() { date } else { .now } },
            set: { self.set(.date($0)) })
    }

    var color: Binding<Color> {
        Binding(
            get: { UIStyles.color(self.get()) ?? .accentColor },
            set: { self.set(.color($0)) })
    }

    var value: Binding<UIValue> {
        Binding(get: { self.get() }, set: { self.set($0) })
    }
}

// MARK: - Styles

/// Converts implicit members and values such as `.blue`, `.title.bold()`, `.leading`,
/// and `RoundedRectangle(cornerRadius: 8)` into SwiftUI values.
enum UIStyles {

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func color(named name: String) -> Color? {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "mint": .mint
        case "teal": .teal
        case "cyan": .cyan
        case "blue": .blue
        case "indigo": .indigo
        case "purple": .purple
        case "pink": .pink
        case "brown": .brown
        case "gray", "grey": .gray
        case "black": .black
        case "white": .white
        case "clear": .clear
        case "primary": .primary
        case "secondary": .secondary
        case "accentColor", "accent": .accentColor
        default: nil
        }
    }

    /// A color from `.blue`, `.blue.opacity(0.5)`, `Color(red:green:blue:)`, or a color value.
    static func color(_ value: UIValue) -> Color? {
        switch value {
        case .color(let color):
            return color
        case .member(let name, let arguments):
            let parts = name.split(separator: ".").map(String.init)
            func argument(_ label: String) -> Double? {
                arguments.first { $0.label == label }?.value.number
            }
            var color: Color
            if parts[0] == "init" {
                if let red = argument("red"), let green = argument("green"), let blue = argument("blue") {
                    color = Color(red: red, green: green, blue: blue, opacity: argument("opacity") ?? 1)
                } else if let hue = argument("hue"), let saturation = argument("saturation"), let brightness = argument("brightness") {
                    color = Color(hue: hue, saturation: saturation, brightness: brightness, opacity: argument("opacity") ?? 1)
                } else if let white = argument("white") {
                    color = Color(white: white, opacity: argument("opacity") ?? 1)
                } else {
                    return nil
                }
            } else if let named = Self.color(named: parts[0]) {
                color = named
            } else {
                return nil
            }
            if parts.dropFirst().contains("opacity"), let opacity = arguments.last(where: { $0.label == nil })?.value.number {
                color = color.opacity(opacity)
            }
            return color
        default:
            return nil
        }
    }

    /// A shape style: a color, a gradient, or a hierarchical style such as `.secondary`.
    static func style(_ value: UIValue?) -> AnyShapeStyle? {
        guard let value else { return nil }
        switch value {
        case .style(let style):
            return style.value
        case .member(let name, _):
            switch name {
            case "primary": return AnyShapeStyle(.primary)
            case "secondary": return AnyShapeStyle(.secondary)
            case "tertiary": return AnyShapeStyle(.tertiary)
            case "quaternary": return AnyShapeStyle(.quaternary)
            case "quinary": return AnyShapeStyle(.quinary)
            case "tint": return AnyShapeStyle(.tint)
            case "foreground": return AnyShapeStyle(.foreground)
            case "background": return AnyShapeStyle(.background)
            case "separator": return AnyShapeStyle(.separator)
            default:
                if name.hasSuffix(".gradient"), let color = color(.member(String(name.dropLast(".gradient".count)), value.memberArguments)) {
                    return AnyShapeStyle(color.gradient)
                }
            }
        default:
            break
        }
        return color(value).map { AnyShapeStyle($0) }
    }

    static func gradient(_ kind: String, _ arguments: [UIArgument]) -> AnyShapeStyle {
        let colors = (arguments.first { $0.label == "colors" }?.value.elements ?? []).compactMap(color)
        let gradient = Gradient(colors: colors.isEmpty ? [.accentColor, .clear] : colors)
        func point(_ label: String, _ fallback: UnitPoint) -> UnitPoint {
            unitPoint(arguments.first { $0.label == label }?.value) ?? fallback
        }
        switch kind {
        case "RadialGradient":
            return AnyShapeStyle(RadialGradient(
                gradient: gradient, center: point("center", .center),
                startRadius: arguments.first { $0.label == "startRadius" }?.value.number ?? 0,
                endRadius: arguments.first { $0.label == "endRadius" }?.value.number ?? 200))
        case "AngularGradient":
            return AnyShapeStyle(AngularGradient(gradient: gradient, center: point("center", .center)))
        default:
            return AnyShapeStyle(LinearGradient(gradient: gradient, startPoint: point("startPoint", .top), endPoint: point("endPoint", .bottom)))
        }
    }

    static func unitPoint(_ value: UIValue?) -> UnitPoint? {
        switch value?.memberName {
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        case "center": .center
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: nil
        }
    }

    /// A font from `.title`, `.title.bold()`, `.system(size: 20, weight: .bold)`, or a font value.
    static func font(_ value: UIValue, base: Font? = nil) -> Font? {
        if case .font(let font) = value { return font }
        guard case .member(let name, let arguments) = value else { return nil }
        var parts = name.split(separator: ".").map(String.init)
        var font: Font
        if let base, parts.first == "font" {
            font = base
        } else if let first = parts.first, let resolved = baseFont(first, arguments) {
            font = resolved
        } else {
            return nil
        }
        parts.removeFirst()
        for part in parts {
            switch part {
            case "bold": font = font.bold()
            case "italic": font = font.italic()
            case "monospaced": font = font.monospaced()
            case "monospacedDigit": font = font.monospacedDigit()
            case "smallCaps": font = font.smallCaps()
            case "weight":
                guard let weight = arguments.last(where: { $0.label == nil }).flatMap({ weight($0.value) }) else { return nil }
                font = font.weight(weight)
            default: return nil
            }
        }
        return font
    }

    private static func baseFont(_ name: String, _ arguments: [UIArgument]) -> Font? {
        if let style = textStyle(name) {
            return .system(style)
        }
        guard name == "system" else { return nil }
        let weight = arguments.first { $0.label == "weight" }.flatMap { self.weight($0.value) }
        let design = arguments.first { $0.label == "design" }.flatMap { self.design($0.value) }
        if let size = arguments.first(where: { $0.label == "size" })?.value.number {
            return .system(size: size, weight: weight ?? .regular, design: design ?? .default)
        }
        if let style = arguments.first(where: { $0.label == nil })?.value.memberName.flatMap(textStyle) {
            return .system(style, design: design, weight: weight)
        }
        return nil
    }

    private static func textStyle(_ name: String) -> Font.TextStyle? {
        switch name {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "title3": .title3
        case "headline": .headline
        case "subheadline": .subheadline
        case "body": .body
        case "callout": .callout
        case "footnote": .footnote
        case "caption": .caption
        case "caption2": .caption2
        default: nil
        }
    }

    static func weight(_ value: UIValue) -> Font.Weight? {
        switch value.memberName {
        case "ultraLight": .ultraLight
        case "thin": .thin
        case "light": .light
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        case "black": .black
        default: nil
        }
    }

    static func design(_ value: UIValue) -> Font.Design? {
        switch value.memberName {
        case "rounded": .rounded
        case "serif": .serif
        case "monospaced": .monospaced
        case "default": .default
        default: nil
        }
    }

    static func horizontalAlignment(_ value: UIValue?) -> HorizontalAlignment? {
        switch value?.memberName {
        case "leading": .leading
        case "center": .center
        case "trailing": .trailing
        default: nil
        }
    }

    static func verticalAlignment(_ value: UIValue?) -> VerticalAlignment? {
        switch value?.memberName {
        case "top": .top
        case "center": .center
        case "bottom": .bottom
        case "firstTextBaseline": .firstTextBaseline
        case "lastTextBaseline": .lastTextBaseline
        default: nil
        }
    }

    static func alignment(_ value: UIValue?) -> Alignment? {
        switch value?.memberName {
        case "leading": .leading
        case "center": .center
        case "trailing": .trailing
        case "top": .top
        case "bottom": .bottom
        case "topLeading": .topLeading
        case "topTrailing": .topTrailing
        case "bottomLeading": .bottomLeading
        case "bottomTrailing": .bottomTrailing
        default: nil
        }
    }

    static func edges(_ value: UIValue) -> Edge.Set? {
        if case .array(let values) = value {
            return values.compactMap(edges).reduce(into: Edge.Set()) { $0.formUnion($1) }
        }
        return switch value.memberName {
        case "all": .all
        case "horizontal": .horizontal
        case "vertical": .vertical
        case "top": .top
        case "bottom": .bottom
        case "leading": .leading
        case "trailing": .trailing
        default: nil
        }
    }

    static func angle(_ value: UIValue?) -> Angle {
        let amount = value?.memberArguments.first?.value.number ?? 0
        return value?.memberName == "radians" ? .radians(amount) : .degrees(amount)
    }

    static func animation(_ value: UIValue?) -> Animation? {
        switch value?.memberName?.split(separator: ".").first {
        case "spring", "bouncy", "snappy", "smooth": .spring
        case "easeIn": .easeIn
        case "easeOut": .easeOut
        case "easeInOut": .easeInOut
        case "linear": .linear
        case nil: nil
        default: .default
        }
    }

    /// A shape from `RoundedRectangle(cornerRadius: 8)`, `Circle()`, or `.rect(cornerRadius: 8)`.
    static func shape(_ value: UIValue?) -> AnyShape? {
        switch value {
        case .record(let type, let fields)?:
            let radius = CGFloat(fields["cornerRadius"]?.number ?? 0)
            switch type {
            case "Rectangle": return AnyShape(Rectangle())
            case "RoundedRectangle": return AnyShape(RoundedRectangle(cornerRadius: radius))
            case "Circle": return AnyShape(Circle())
            case "Capsule": return AnyShape(Capsule())
            case "Ellipse": return AnyShape(Ellipse())
            default: return nil
            }
        case .member(let name, let arguments)?:
            let radius = CGFloat(arguments.first { $0.label == "cornerRadius" }?.value.number ?? 0)
            switch name {
            case "rect": return AnyShape(RoundedRectangle(cornerRadius: radius))
            case "circle": return AnyShape(Circle())
            case "capsule": return AnyShape(Capsule())
            case "ellipse": return AnyShape(Ellipse())
            default: return nil
            }
        default:
            return nil
        }
    }

    /// A grid column from `GridItem(.flexible())`, `.fixed(80)`, or `.adaptive(minimum: 100)`.
    static func gridItem(_ value: UIValue) -> GridItem {
        let size = value.field("size") ?? .null
        let spacing = value.field("spacing")?.number.map { CGFloat($0) }
        func argument(_ label: String?) -> CGFloat? {
            size.memberArguments.first { $0.label == label }?.value.number.map { CGFloat($0) }
        }
        switch size.memberName {
        case "fixed":
            return GridItem(.fixed(argument(nil) ?? 100), spacing: spacing)
        case "adaptive":
            return GridItem(.adaptive(minimum: argument("minimum") ?? 80, maximum: argument("maximum") ?? .infinity), spacing: spacing)
        default:
            return GridItem(.flexible(minimum: argument("minimum") ?? 10, maximum: argument("maximum") ?? .infinity), spacing: spacing)
        }
    }
}

// MARK: - Charts and maps

/// A mark built by `BarMark`, `LineMark`, `AreaMark`, `PointMark`, `RuleMark`, or `SectorMark`,
/// whose values come from `.value("Label", value)`.
struct UIChartMark {
    let kind: String
    let x: (label: String, value: UIValue)?
    let y: (label: String, value: UIValue)?
    let angle: (label: String, value: Double)?
    let innerRadius: Double
    let series: (label: String, value: String)?
    let color: Color?

    init?(_ value: UIValue) {
        guard case .record(let kind, let fields) = value, kind.hasSuffix("Mark") else { return nil }
        func plottable(_ name: String) -> (label: String, value: UIValue)? {
            guard case .member("value", let arguments)? = fields[name], arguments.count >= 2 else { return nil }
            return (arguments[0].value.text, arguments[1].value)
        }
        self.kind = kind
        x = plottable("x")
        y = plottable("y")
        angle = plottable("angle").map { ($0.label, $0.value.number ?? 0) }
        innerRadius = fields["innerRadius"]?.memberArguments.first?.value.number ?? 0
        series = plottable("series").map { ($0.label, $0.value.text) }
        color = fields["color"].flatMap(UIStyles.color)
    }
}

struct UIChart: View {
    let marks: [UIChartMark]

    var body: some View {
        Chart(marks.indices, id: \.self) { index in
            UIChartMarkContent(mark: marks[index])
        }
        .frame(minHeight: 180, idealHeight: 220)
    }
}

private struct UIChartMarkContent: ChartContent {
    let mark: UIChartMark

    var body: some ChartContent {
        if let series = mark.series {
            styled.foregroundStyle(by: .value(series.label, series.value))
        } else if let color = mark.color {
            styled.foregroundStyle(color)
        } else {
            styled
        }
    }

    @ChartContentBuilder
    private var styled: some ChartContent {
        let xLabel = mark.x?.label ?? ""
        let yLabel = mark.y?.label ?? ""
        let yNumber = mark.y?.value.number ?? 0
        if mark.kind == "SectorMark", let angle = mark.angle {
            SectorMark(angle: .value(angle.label, angle.value), innerRadius: .ratio(mark.innerRadius), angularInset: 1)
        } else if mark.kind == "RuleMark" {
            RuleMark(y: .value(yLabel, yNumber))
        } else if case .string(let category)? = mark.y?.value, let xNumber = mark.x?.value.number {
            // A horizontal bar: categories on the y axis.
            BarMark(x: .value(xLabel, xNumber), y: .value(yLabel, category))
        } else if case .date(let date)? = mark.x?.value {
            xyMark(x: .value(xLabel, date), y: .value(yLabel, yNumber))
        } else if let x = mark.x?.value, x.typeName != "String", let xNumber = x.number {
            xyMark(x: .value(xLabel, xNumber), y: .value(yLabel, yNumber))
        } else {
            xyMark(x: .value(xLabel, mark.x?.value.text ?? ""), y: .value(yLabel, yNumber))
        }
    }

    @ChartContentBuilder
    private func xyMark<X: Plottable>(x: PlottableValue<X>, y: PlottableValue<Double>) -> some ChartContent {
        switch mark.kind {
        case "LineMark": LineMark(x: x, y: y)
        case "AreaMark": AreaMark(x: x, y: y)
        case "PointMark": PointMark(x: x, y: y)
        default: BarMark(x: x, y: y)
        }
    }
}

struct UIMapMarker {
    let title: String
    let systemImage: String?
    let coordinate: CLLocationCoordinate2D
}

struct UIMap: View {
    let markers: [UIMapMarker]

    var body: some View {
        Map {
            ForEach(markers.indices, id: \.self) { index in
                let marker = markers[index]
                if let systemImage = marker.systemImage {
                    Marker(marker.title, systemImage: systemImage, coordinate: marker.coordinate)
                } else {
                    Marker(marker.title, coordinate: marker.coordinate)
                }
            }
        }
        .frame(minHeight: 200, idealHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - ModelCraft components

/// `Card("Title", systemImage: "star") { … }`: a titled group on a subtle background.
struct UICard: View {
    let title: String?
    let icon: String?
    let content: AnyView

    init(title: String?, icon: String?, @ViewBuilder content: () -> AnyView) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                if let icon {
                    Label(title, systemImage: icon)
                        .font(.headline)
                } else {
                    Text(title)
                        .font(.headline)
                }
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// `Stat("Revenue", value: "$1.2M", detail: "Q3", trend: .up)`: a key figure.
struct UIStat: View {
    let label: String
    let value: String
    let detail: String?
    let trend: String?
    let icon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let icon {
                Label(label, systemImage: icon)
            } else {
                Text(label)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                switch trend {
                case "up":
                    Image(systemName: "arrow.up.right")
                        .accessibilityLabel("Increasing")
                case "down":
                    Image(systemName: "arrow.down.right")
                        .accessibilityLabel("Decreasing")
                case "flat":
                    Image(systemName: "arrow.right")
                        .accessibilityLabel("Unchanged")
                default:
                    EmptyView()
                }
            }
            if let detail {
                Text(detail)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// `Callout("Text", kind: .warning, title: "Title")`: a tinted note.
struct UICallout: View {
    let kind: String?
    let title: String?
    let text: String

    var body: some View {
        let (icon, color): (String, Color) = switch kind {
        case "success": ("checkmark.circle.fill", .green)
        case "warning": ("exclamationmark.triangle.fill", .orange)
        case "error": ("xmark.octagon.fill", .red)
        default: ("info.circle.fill", .blue)
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.headline)
                }
                Text(UIStyles.markdown(text))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
