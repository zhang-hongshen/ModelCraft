//
//  GenerativeUIView.swift
//  ModelCraft
//
//  Created by Hongshen on 10/10/26.
//

import SwiftUI
import Charts
import MapKit

/// Renders the components of one `ui` block.
struct GenerativeUIView: View {

    let components: [GenerativeUIComponent]
    /// Sends text as the user's next message; `nil` disables buttons and forms.
    let send: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(components.indices, id: \.self) { index in
                GenerativeUIComponentView(component: components[index], send: send)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }
}

private struct GenerativeUIComponentView: View {

    let component: GenerativeUIComponent
    let send: ((String) -> Void)?

    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .modifier(GenerativeUIModifiers(component: component))
    }

    @ViewBuilder
    private var content: some View {
        switch component.type?.lowercased() {
        // Containers
        case "vstack", "column":
            VStack(alignment: horizontalAlignment, spacing: spacing(default: 8)) {
                children
            }
        case "hstack", "row":
            HStack(alignment: verticalAlignment, spacing: spacing(default: 12)) {
                children
            }
        case "zstack":
            ZStack(alignment: GenerativeUIModifiers.alignment(component.alignment) ?? .center) {
                children
            }
        case "scrollview":
            if component.axis == "horizontal" {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: spacing(default: 12)) { children }
                }
            } else {
                VStack(alignment: .leading, spacing: spacing(default: 8)) { children }
            }
        case "grid":
            grid
        case "gridrow":
            GridRow { children }
        case "lazyvgrid":
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: CGFloat(min(max(component.minWidth ?? 160, 60), 600)),
                              maximum: .infinity),
                    spacing: spacing(default: 12),
                    alignment: .topLeading)],
                alignment: .leading,
                spacing: spacing(default: 12)
            ) {
                children
            }
        case "section":
            section
        case "groupbox":
            GroupBox {
                VStack(alignment: .leading, spacing: spacing(default: 8)) { children }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                if let title = component.title {
                    Text(title)
                }
            }
        case "card":
            card
        case "disclosuregroup":
            GenerativeUIDisclosureGroup(component: component, send: send)
        case "tabview":
            GenerativeUITabView(component: component, send: send)
        case "list":
            list
        case "form":
            GenerativeUIForm(
                title: component.title,
                submitTitle: component.submit,
                fields: component.fields ?? [],
                send: send)
        // Content
        case "text":
            text
        case "label":
            if let icon = component.icon {
                Label(component.title ?? component.text ?? "", systemImage: icon)
            } else {
                Text(component.title ?? component.text ?? "")
            }
        case "image":
            if let icon = component.icon {
                Image(systemName: icon)
                    .accessibilityLabel(component.label ?? "")
            }
        case "divider":
            Divider()
        case "spacer":
            Spacer(minLength: 0)
        case "labeledcontent":
            LabeledContent(component.label ?? component.title ?? "") {
                Text(markdown(component.value ?? component.text ?? ""))
                    .textSelection(.enabled)
            }
        case "progressview":
            progress
        case "gauge":
            gauge
        case "link":
            if let url = component.url.flatMap(URL.init(string:)) {
                Link(component.title ?? component.url ?? "", destination: url)
            }
        case "stat":
            stat
        case "callout":
            callout
        case "table":
            table
        case "chart":
            chart
        case "map":
            map
        case "button":
            button
        default:
            EmptyView()
        }
    }

    private var children: some View {
        let children = component.children ?? []
        return ForEach(children.indices, id: \.self) { index in
            GenerativeUIComponentView(component: children[index], send: send)
        }
    }

    private func spacing(default value: CGFloat) -> CGFloat {
        component.spacing.map { CGFloat(min(max($0, 0), 48)) } ?? value
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch component.alignment {
        case "center": .center
        case "trailing": .trailing
        default: .leading
        }
    }

    /// `row` keeps its original top alignment; `hstack` centers like SwiftUI.
    private var verticalAlignment: VerticalAlignment {
        switch component.alignment {
        case "top": .top
        case "bottom": .bottom
        case "center": .center
        case "firstTextBaseline": .firstTextBaseline
        default: component.type?.lowercased() == "row" ? .top : .center
        }
    }

    // MARK: Containers

    /// `gridRow` children are rows; any other child spans the grid, such as a divider.
    private var grid: some View {
        let rows = component.children ?? []
        return Grid(alignment: .leading, horizontalSpacing: spacing(default: 16), verticalSpacing: 8) {
            ForEach(rows.indices, id: \.self) { index in
                let row = rows[index]
                if row.type?.lowercased() == "gridrow" {
                    let cells = row.children ?? []
                    GridRow {
                        ForEach(cells.indices, id: \.self) { cell in
                            GenerativeUIComponentView(component: cells[cell], send: send)
                        }
                    }
                } else {
                    GenerativeUIComponentView(component: row, send: send)
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    private var section: some View {
        VStack(alignment: .leading, spacing: spacing(default: 8)) {
            if let title = component.title {
                Text(title)
                    .font(.headline)
            }
            children
            if let footer = component.footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: spacing(default: 10)) {
            if let title = component.title {
                if let icon = component.icon {
                    Label(title, systemImage: icon)
                        .font(.headline)
                } else {
                    Text(title)
                        .font(.headline)
                }
            }
            children
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// `items` are bulleted or numbered rows; `children` follow as their own rows.
    private var list: some View {
        let items = component.items ?? []
        return VStack(alignment: .leading, spacing: spacing(default: 6)) {
            ForEach(items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: component.style == "numbered" ? "\(index + 1)." : "•")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(markdown(items[index]))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            children
        }
    }

    // MARK: Content

    /// `style` is a shorthand; without it the text inherits the font and color set by
    /// its own `font` and `color` or by its containers.
    private var text: some View {
        let font: Font? = switch component.style {
        case "title": .title2.weight(.semibold)
        case "headline": .headline
        case "caption": .caption
        default: nil
        }
        let isSecondary = component.style == "secondary" || component.style == "caption"
        return Text(markdown(component.text ?? ""))
            .transformEnvironment(\.font) { inherited in
                if let font { inherited = font }
            }
            .foregroundStyle(isSecondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.foreground))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var progress: some View {
        if let value = component.numberValue {
            let total = max(component.total ?? 1, .ulpOfOne)
            ProgressView(value: min(max(value, 0), total), total: total) {
                if let label = component.label ?? component.title {
                    Text(label)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var gauge: some View {
        let minimum = component.minimum ?? 0
        let maximum = max(component.maximum ?? 1, minimum + .ulpOfOne)
        let value = min(max(component.numberValue ?? minimum, minimum), maximum)
        return Gauge(value: value, in: minimum...maximum) {
            Text(component.label ?? component.title ?? "")
        } currentValueLabel: {
            Text(component.detail ?? component.value ?? "")
        }
    }

    private var stat: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let icon = component.icon {
                Label(component.label ?? "", systemImage: icon)
            } else {
                Text(component.label ?? "")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(component.value ?? "")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                switch component.trend {
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
            if let detail = component.detail {
                Text(detail)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var callout: some View {
        let (icon, color): (String, Color) = switch component.kind {
        case "success": ("checkmark.circle.fill", .green)
        case "warning": ("exclamationmark.triangle.fill", .orange)
        case "error": ("xmark.octagon.fill", .red)
        default: ("info.circle.fill", .blue)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title = component.title {
                    Text(title)
                        .font(.headline)
                }
                Text(markdown(component.text ?? ""))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var table: some View {
        let columns = component.columns ?? []
        let rows = component.rows ?? []
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                ForEach(columns.indices, id: \.self) { column in
                    Text(columns[column])
                        .font(.headline)
                }
            }
            Divider()
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row].indices, id: \.self) { column in
                        Text(markdown(rows[row][column]))
                            .foregroundStyle(column == 0 ? HierarchicalShapeStyle.secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var chart: some View {
        // A point that is still streaming has no label or value yet.
        let points = (component.points ?? []).filter { $0.label != nil && $0.value != nil }
        let xTitle = component.x ?? ""
        let yTitle = component.y ?? ""
        return Chart(points.indices, id: \.self) { index in
            let label = points[index].label ?? ""
            let value = points[index].value ?? 0
            let series = points[index].series ?? ""
            switch component.kind {
            case "line":
                LineMark(x: .value(xTitle, label), y: .value(yTitle, value))
                    .foregroundStyle(by: .value("Series", series))
            case "point":
                PointMark(x: .value(xTitle, label), y: .value(yTitle, value))
                    .foregroundStyle(by: .value("Series", series))
            case "area":
                AreaMark(x: .value(xTitle, label), y: .value(yTitle, value))
                    .foregroundStyle(by: .value("Series", series))
            case "pie":
                SectorMark(angle: .value(yTitle, value), innerRadius: .ratio(0.5), angularInset: 1)
                    .foregroundStyle(by: .value(xTitle, label))
            default:
                BarMark(x: .value(xTitle, label), y: .value(yTitle, value))
                    .foregroundStyle(by: .value("Series", series))
            }
        }
        .chartXAxisLabel(xTitle)
        .chartYAxisLabel(yTitle)
        .chartLegend(component.kind == "pie" || points.contains { $0.series != nil } ? .automatic : .hidden)
        .frame(minHeight: 180, idealHeight: 220)
    }

    private var map: some View {
        let places = (component.places ?? []).compactMap { place -> (title: String, coordinate: CLLocationCoordinate2D)? in
            guard let latitude = place.latitude, let longitude = place.longitude else { return nil }
            return (place.title ?? "", CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        return Map {
            ForEach(places.indices, id: \.self) { index in
                Marker(places[index].title, coordinate: places[index].coordinate)
            }
        }
        .frame(minHeight: 200, idealHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// A button either sends its `send` text as the user's next message or opens its `url`.
    @ViewBuilder
    private var button: some View {
        let title = component.title ?? ""
        if let message = component.send {
            Button(title) { send?(message) }
                .disabled(send == nil)
        } else if let url = component.url.flatMap(URL.init(string:)) {
            Button(title) { openURL(url) }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Sends the field values as one user message with one `label: value` line per field.
private struct GenerativeUIForm: View {

    let title: String?
    let submitTitle: String?
    let fields: [GenerativeUIFormField]
    let send: ((String) -> Void)?

    /// Values the user changed, by field position. Other fields show their initial value,
    /// which keeps working while fields are still streaming in.
    @State private var edits: [Int: String] = [:]
    @State private var isSubmitted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            Form {
                ForEach(fields.indices, id: \.self) { index in
                    field(at: index)
                }
            }
            .formStyle(.columns)
            HStack {
                Spacer()
                Button(submitTitle ?? String(localized: "Submit")) {
                    isSubmitted = true
                    send?(message)
                }
                .buttonStyle(.borderedProminent)
                .disabled(send == nil)
            }
        }
        .disabled(isSubmitted)
    }

    @ViewBuilder
    private func field(at index: Int) -> some View {
        let field = fields[index]
        let label = field.label ?? ""
        switch field.kind {
        case "toggle":
            Toggle(label, isOn: Binding(
                get: { value(at: index) == "true" },
                set: { edits[index] = $0 ? "true" : "false" }))
        case "picker":
            Picker(label, selection: binding(at: index)) {
                ForEach(field.options ?? [], id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        case "slider":
            let range = Self.range(of: field)
            Slider(value: numberBinding(at: index, in: range), in: range, step: Self.step(of: field, in: range)) {
                Text(verbatim: "\(label): \(value(at: index))")
            }
        case "stepper":
            let range = Self.range(of: field)
            Stepper(value: numberBinding(at: index, in: range), in: range, step: Self.step(of: field, in: range)) {
                Text(verbatim: "\(label): \(value(at: index))")
            }
        case "date":
            DatePicker(label, selection: dateBinding(at: index), displayedComponents: .date)
        default:
            TextField(label, text: binding(at: index), axis: .vertical)
        }
    }

    private func value(at index: Int) -> String {
        if let edit = edits[index] {
            return edit
        }
        let field = fields[index]
        return switch field.kind {
        case "toggle": field.on == true ? "true" : "false"
        case "picker": field.value ?? field.options?.first ?? ""
        case "slider", "stepper": field.value ?? Self.text(Self.range(of: field).lowerBound)
        case "date": field.value ?? Self.dateFormat.string(from: .now)
        default: field.value ?? ""
        }
    }

    private func binding(at index: Int) -> Binding<String> {
        Binding(
            get: { value(at: index) },
            set: { edits[index] = $0 })
    }

    private func numberBinding(at index: Int, in range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { min(max(Double(value(at: index)) ?? range.lowerBound, range.lowerBound), range.upperBound) },
            set: { edits[index] = Self.text($0) })
    }

    /// Dates are exchanged as `yyyy-MM-dd`, which is also how they appear in the sent message.
    private func dateBinding(at index: Int) -> Binding<Date> {
        Binding(
            get: { Self.dateFormat.date(from: value(at: index)) ?? .now },
            set: { edits[index] = Self.dateFormat.string(from: $0) })
    }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func range(of field: GenerativeUIFormField) -> ClosedRange<Double> {
        let minimum = field.minimum ?? 0
        return minimum...max(field.maximum ?? 100, minimum + 1)
    }

    private static func step(of field: GenerativeUIFormField, in range: ClosedRange<Double>) -> Double {
        max(field.step ?? 1, (range.upperBound - range.lowerBound) / 1000)
    }

    private static func text(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : number.formatted(.number.precision(.fractionLength(0...2)))
    }

    private var message: String {
        var lines = title.map { [$0] } ?? []
        for index in fields.indices {
            let value = value(at: index)
            let shown = switch fields[index].kind {
            case "toggle": value == "true" ? String(localized: "Yes") : String(localized: "No")
            default: value
            }
            lines.append("\(fields[index].label ?? ""): \(shown)")
        }
        return lines.joined(separator: "\n")
    }
}

/// A collapsible group, initially expanded when `expanded` is true.
private struct GenerativeUIDisclosureGroup: View {

    let component: GenerativeUIComponent
    let send: ((String) -> Void)?

    @State private var isExpanded: Bool

    init(component: GenerativeUIComponent, send: ((String) -> Void)?) {
        self.component = component
        self.send = send
        _isExpanded = State(initialValue: component.expanded ?? false)
    }

    var body: some View {
        let children = component.children ?? []
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(children.indices, id: \.self) { index in
                    GenerativeUIComponentView(component: children[index], send: send)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text(component.title ?? "")
        }
    }
}

/// Tabs chosen with a segmented control; each child is one tab named by its `title`.
private struct GenerativeUITabView: View {

    let component: GenerativeUIComponent
    let send: ((String) -> Void)?

    @State private var selection = 0

    var body: some View {
        let tabs = component.children ?? []
        VStack(alignment: .leading, spacing: 10) {
            Picker(selection: $selection) {
                ForEach(tabs.indices, id: \.self) { index in
                    Text(tabs[index].title ?? String(index + 1)).tag(index)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if tabs.indices.contains(selection) {
                GenerativeUIComponentView(component: tabs[selection], send: send)
            }
        }
    }
}

/// SwiftUI modifiers available on every component: `font`, `weight`, `color`, `background`,
/// `padding`, `cornerRadius`, `width`, `height`, and `fillWidth`. A modifier that is not set
/// leaves inherited values unchanged. Colors are adaptive system colors and hierarchical
/// styles, so blocks stay legible in both appearances; sizes are clamped.
private struct GenerativeUIModifiers: ViewModifier {

    let component: GenerativeUIComponent

    func body(content: Content) -> some View {
        content
            .transformEnvironment(\.font) { font in
                guard component.font != nil || component.weight != nil else { return }
                var resolved = Self.font(component.font) ?? font ?? .body
                if let weight = Self.weight(component.weight) {
                    resolved = resolved.weight(weight)
                }
                font = resolved
            }
            .foregroundStyle(Self.style(component.color) ?? AnyShapeStyle(.foreground))
            .frame(
                width: component.width.map { Self.clamp($0, 0, 800) },
                height: component.height.map { Self.clamp($0, 0, 600) })
            .frame(maxWidth: component.fillWidth == true ? .infinity : nil, alignment: .leading)
            .padding(component.padding.map { Self.clamp($0, 0, 40) } ?? 0)
            .background(
                Self.style(component.background) ?? AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: component.cornerRadius.map { Self.clamp($0, 0, 32) } ?? 0))
    }

    static func alignment(_ name: String?) -> Alignment? {
        switch name {
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

    private static func font(_ name: String?) -> Font? {
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

    private static func weight(_ name: String?) -> Font.Weight? {
        switch name {
        case "light": .light
        case "regular": .regular
        case "medium": .medium
        case "semibold": .semibold
        case "bold": .bold
        case "heavy": .heavy
        default: nil
        }
    }

    private static func style(_ name: String?) -> AnyShapeStyle? {
        let color: Color? = switch name {
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
        case "gray": .gray
        case "accentColor": .accentColor
        default: nil
        }
        if let color { return AnyShapeStyle(color) }
        return switch name {
        case "primary": AnyShapeStyle(.primary)
        case "secondary": AnyShapeStyle(.secondary)
        case "tertiary": AnyShapeStyle(.tertiary)
        case "quaternary": AnyShapeStyle(.quaternary)
        case "quinary": AnyShapeStyle(.quinary)
        default: nil
        }
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> CGFloat {
        CGFloat(min(max(value, lower), upper))
    }
}
