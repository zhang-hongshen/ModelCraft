//
//  UIManager.swift
//  ModelCraft
//
//  Created by Hongshen on 14/6/26.
//

import ApplicationServices
import AppKit

class UIManager {
    
    static let shared = UIManager()
    
    private let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 5
        return cache
    }()
    
    func getUITree(appID: String, element: AXUIElement, depth: Int, maxDepth: Int) -> [String] {
        cache.removeObject(forKey: appID as NSString)
        var interactiveElements: [Element] = []
        guard let root = describeElement(
            appID: appID,
            element: element,
            depth: depth,
            maxDepth: maxDepth,
            cache: &interactiveElements
        ) else {
            return []
        }
        cache.setObject(interactiveElements as NSArray, forKey: appID as NSString)
        return root.getActionableElmenets()
    }
    
    
    private func describeElement(appID: String, element: AXUIElement, parent: Element? = nil, depth: Int, maxDepth: Int,
                                 cache: inout [Element]) -> Element? {
        if depth > maxDepth { return nil }
        
        let node = Element(
            role: element.role ?? kAXUnknownRole,
            identifier: element.identifier,
            actions: element.actions,
            attributes: getAttributes(element),
            uiElment: element
        )
        
        if node.interactive {
            node.index = cache.count
            cache.append(node)
        }
        
        let children = childElements(
            for: element,
            role: node.role
        )
        node.children = children.compactMap { describeElement(
            appID: appID,
            element: $0,
            parent: node,
            depth: depth + 1,
            maxDepth: maxDepth,
            cache: &cache
        )}
        return node
    }
    
    private func childElements(
        for element: AXUIElement,
        role: String
    ) -> [AXUIElement] {

        switch role {

        case kAXApplicationRole:

            let windows: [AXUIElement] =
                element.getAttribute(kAXWindowsAttribute) ?? []

            return windows.filter { window in

                var size = CGSize.zero

                guard let value: AXValue = window.getAttribute(kAXSizeAttribute) else {
                    return true
                }
                
                guard AXValueGetValue(value, .cgSize, &size) else {
                    return true
                }

                return size.width > 1 || size.height > 1
            }

        case kAXTableRole,
             kAXOutlineRole,
             kAXGridRole:

            return element.getAttribute(kAXVisibleRowsAttribute)
                ?? element.getAttribute(kAXRowsAttribute)
                ?? []

        case kAXRowRole:
            return element.getAttribute(kAXVisibleCellsAttribute)
                ?? []

        case kAXTabGroupRole:
            return element.getAttribute(kAXTabsAttribute)
                ?? element.children

        case kAXListRole:
            return
                element.getAttribute(kAXVisibleChildrenAttribute)
                ?? element.children

        default:
            return element.children
        }
    }
    
    // MARK: - Element Search
    func searchElement(appID: String, index: Int) -> AXUIElement? {
        guard let cachedArray = cache.object(forKey: appID as NSString) as? [Element] else {
            return nil
        }
        
        guard index >= 0 && index < cachedArray.count else {
            return nil
        }
        
        return cachedArray[index].uiElment
    }
    
    private func getAttributes(_ element: AXUIElement) -> [String:Value] {
        var attributes: [String:Value] = [:]
        
        if (element.title == nil || element.title!.isEmpty),
           [kAXButtonRole, kAXImageRole, kAXMenuButtonRole, kAXCheckBoxRole, kAXRadioButtonRole].contains(element.role ?? ""),
            let title = [ element.description, element.help].compactMap ({ $0 })
            .first (where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            attributes["title"] = .string(title)
        }
        if let value = element.value {
            attributes["value"] = value
        }
        
        if let enabled = element.enabled {
            attributes["enabled"] = .bool(enabled)
        }
        switch element.role {
        case kAXColumnRole:
            if let index: Int = element.getAttribute(kAXIndexAttribute) {
                attributes["column_index"] = .int(index)
            }
        case kAXRowRole:
            if let selected: Bool = element.getAttribute(kAXSelectedAttribute) {
                attributes["selected"] = .bool(selected)
            }
            if let index: Int = element.getAttribute(kAXIndexAttribute) {
                attributes["row_index"] = .int(index)
            }
            if element.subrole == kAXOutlineRowSubrole {
                if let level: Int = element.getAttribute(kAXDisclosureLevelAttribute) {
                    attributes["disclosure_level"] = .int(level)
                }
                if let expanded: Bool = element.getAttribute(kAXDisclosingAttribute) {
                    attributes["expanded"] = .bool(expanded)
                }
            }
        case kAXTextFieldRole, kAXTextAreaRole:
            if let editable: Bool = element.getAttribute(kAXIsEditableAttribute) {
                attributes["editable"] = .bool(editable)
            }
            if let selectedText: String = element.getAttribute(kAXSelectedTextAttribute) {
                attributes["selected_text"] = .string(selectedText)
            }
            if let placeholder: String = element.getAttribute(kAXPlaceholderValueAttribute) {
                attributes["placeholder"] = .string(placeholder)
            }
            if let numberOfCharacters: Int = element.getAttribute(kAXNumberOfCharactersAttribute) {
                attributes["number_of_characters"] = .int(numberOfCharacters)
            }
            if let insertionPointLineNumber: Int = element.getAttribute(kAXInsertionPointLineNumberAttribute) {
                attributes["insertion_point_line_number"] = .int(insertionPointLineNumber)
            }
        case kAXRadioButtonRole:
            if let selected: Bool = element.getAttribute(kAXSelectedAttribute) {
                attributes["selected"] = .bool(selected)
            }
        case kAXSliderRole:
            if let minValue: Double = element.getAttribute(kAXMinValueAttribute) {
                attributes["min_value"] = .double(minValue)
            }
            if let maxValue: Double = element.getAttribute(kAXMaxValueAttribute)  {
                attributes["max_value"] = .double(maxValue)
            }
            if let allowedValues: [Double] = element.getAttribute(kAXAllowedValuesAttribute)  {
                attributes["allowed_values"] = .array(allowedValues.map(Value.double))
            }
            if let orientation: String = element.getAttribute(kAXOrientationAttribute)  {
                attributes["orientation"] = .string(orientation)
            }
            if let valueIncrement: Double = element.getAttribute(kAXValueIncrementAttribute) {
                attributes["value_increment"] = .double(valueIncrement)
            }
        case kAXProgressIndicatorRole, kAXLevelIndicatorRole:
            if let minValue: Double = element.getAttribute(kAXMinValueAttribute) {
                attributes["min_value"] = .double(minValue)
            }
            if let maxValue: Double = element.getAttribute(kAXMaxValueAttribute)  {
                attributes["max_value"] = .double(maxValue)
            }
        case kAXScrollBarRole:
            if let orientation: String = element.getAttribute(kAXOrientationAttribute)  {
                attributes["orientation"] = .string(orientation)
            }
            if let valueIncrement: Double = element.getAttribute(kAXValueIncrementAttribute) {
                attributes["value_increment"] = .double(valueIncrement)
            }
        case kAXIncrementorRole:
            if let valueIncrement: Double = element.getAttribute(kAXValueIncrementAttribute) {
                attributes["value_increment"] = .double(valueIncrement)
            }
        case kAXMenuButtonRole, kAXPopUpButtonRole:
            if element.value == nil, let children: [AXUIElement] = element.getAttribute(kAXChildrenAttribute) {
                for child in children {
                    if let selected: Bool = child.getAttribute(kAXSelectedAttribute), selected,
                       let title = child.title {
                        attributes["selected_value"] = .string(title)
                        break
                    }
                }
            }
        case kAXWindowRole, kAXSheetRole:
            if let main: Bool = element.getAttribute(kAXMainAttribute)  {
                attributes["is_main_window"] = .bool(main)
            }
        default:
            break
        }
        return attributes
    }
}


class Element {
    var index: Int?
    let role: String
    var identifier: String?
    var actions: [String]
    var children: [Element]
    var parent: Element?
    var attributes: [String:Value]
    var uiElment: AXUIElement
    
    
    init(index: Int? = nil, role: String, identifier: String? = nil, actions: [String], children: [Element] = [],
         parent: Element? = nil, attributes: [String:Value] = [:], uiElment: AXUIElement) {
        self.index = index
        self.role = role
        self.identifier = identifier
        self.actions = actions
        self.children = children
        self.parent = parent
        self.attributes = attributes
        self.uiElment = uiElment
    }
    
    var accessibilityPath: String {
        var pathComponents: [String] = []
        var current: Element? = self
        
        while let currentNode = current, let parent = currentNode.parent {
            let role = currentNode.role
            var identifiers: [String] = []
            
            if let titleVal = currentNode.attributes["title"], case .string(let titleStr) = titleVal {
                identifiers.append("title=\(titleStr)")
            }
            
            let siblings = parent.children.filter { $0.role == role }
            var pathComponent = role
            
            if siblings.count > 1 {
                if let index = siblings.firstIndex(where: { $0 === currentNode }) {
                    pathComponent = "\(role)[\(index + 1)]"
                }
            }
            
            if !identifiers.isEmpty {
                pathComponent += "(\(identifiers.joined(separator: ",")))"
            }
            
            pathComponents.append(pathComponent)
            
            current = parent
        }
        pathComponents.reverse()
        return "/" + pathComponents.joined(separator: "/")
    }
    
    func getActionableElmenets() -> [String] {
        
        return getActionableElmenets(self)
    }
    
    private func getActionableElmenets(_ element: Element) -> [String] {
        
        var attributesText = ""
        for (key, value) in element.attributes {
            attributesText += " \(key)=\(value.description)"
        }
        
        if !element.actions.isEmpty {
            attributesText += " actions=\(element.actions.joined(separator: ", "))"
        }
        
        var result: [String] = []
        if let index = element.index {
            result.append("\(index)[:]<\(element.role)\(attributesText)>[interactive]")
        }
        else if (element.role == kAXStaticTextRole || element.role == kAXTextFieldRole) {
            if !element.interactive {
                if element.parent == nil || element.parent?.role == kAXRowRole || element.parent?.interactive == true {
                    result.append("_[:]<\(element.role)\(attributesText)>[context]")
                }
            }
        }
        
        for child in element.children {
            result.append(contentsOf: getActionableElmenets(child))
        }
        return result
    }
    
    
    var interactive : Bool {
        if actions.isEmpty {
            return false
        }
        
        let interactiveActions = [
            kAXPressAction,
            kAXIncrementAction,
            kAXDecrementAction,
            kAXConfirmAction,
            kAXCancelAction,
            kAXShowAlternateUIAction,
            kAXShowDefaultUIAction,
            kAXRaiseAction,
            kAXShowMenuAction,
            kAXPickAction
        ]
        
        let hasInteractive = actions.contains(where: interactiveActions.contains)
        
        var enabled: Bool {
            guard let attribute = self.attributes["enabled"], case .bool(let enabled) = attribute else {
                return false
            }
            return enabled
        }
        
        if actions.contains("AXSetValue") && role == kAXTextFieldRole {
            return enabled == true
        }
        
        if actions.contains(kAXPressAction), [kAXButtonRole, "AXLink"].contains(role) {
            return enabled == true
        }
        
        return hasInteractive
    }
}
