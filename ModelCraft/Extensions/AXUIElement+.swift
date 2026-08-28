//
//  AXUIElement+.swift
//  ModelCraft
//
//  Created by Hongshen on 14/6/26.
//

import ApplicationServices

extension AXUIElement {
    
    var role: String? { getAttribute(kAXRoleAttribute) }
    var subrole: String? { getAttribute(kAXSubroleAttribute) }
    var identifier: String? { getAttribute(kAXIdentifierAttribute) }
    var title: String? { getAttribute(kAXTitleAttribute) }
    var description: String? { getAttribute(kAXDescriptionAttribute) }
    var value: Value? {
        switch role ?? kAXUnknownRole {
        case kAXCheckBoxRole, kAXRadioButtonRole:
            (getAttribute(kAXValueAttribute) as Int?).map { .bool($0 == 1) }
        case kAXSliderRole, kAXScrollBarRole, kAXProgressIndicatorRole, kAXLevelIndicatorRole:
            
            (getAttribute(kAXValueAttribute) as Double?).map { .double($0) }
        default:
            (getAttribute(kAXValueAttribute) as String?).map { .string($0) }
        }
    }
    var help: String? { getAttribute(kAXHelpAttribute) }
    var focused: Bool? { getAttribute(kAXFocusedAttribute) }
    var enabled: Bool? {getAttribute(kAXEnabledAttribute) }
    var position: CGPoint? {
        guard let positionValue: AXValue = getAttribute(kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }
    var size: CGSize? {
        guard let sizeValue: AXValue = getAttribute(kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
    var frame: CGRect? {
        guard let point: CGPoint = position, let size: CGSize = size else { return nil }
        return CGRect(origin: point, size: size)
    }
    var children: [AXUIElement] { getAttribute(kAXChildrenAttribute) ?? [] }
    var parent: AXUIElement? { getAttribute(kAXParentAttribute) }
    var actions: [String] {
        var actionNames: CFArray?
        let result = AXUIElementCopyActionNames(self, &actionNames)
        guard result == .success, let names = actionNames as? [String] else { return [] }
        return names
    }
    
    var attributeNames: [String] {
        var attributeNames: CFArray?
        let result = AXUIElementCopyAttributeNames(self, &attributeNames)
        guard result == .success, let names = attributeNames as? [String] else { return [] }
        return names
    }
    
    func getAttribute<T>(_ attribute: String) -> T? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(self, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }
    
    func setAttribute(_ attribute: String, value: CFTypeRef) -> AXError {
        let error = AXUIElementSetAttributeValue(self, attribute as CFString, value)
        return error
    }
    
    @discardableResult
    func performAction(_ action: String) -> Bool {
        guard actions.contains(action) else {
            print("⚠️ Warning: Element \(self.role) does not support action: \(action)")
            return false
        }
        
        let result = AXUIElementPerformAction(self, action as CFString)
        return result == .success
    }
    
    
    
    
}
 
