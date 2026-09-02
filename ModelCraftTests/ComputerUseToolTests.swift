//
//  ComputerUseToolTests.swift
//  ModelCraftTests
//
//  Created by Hongshen on 13/6/26.
//

import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import ModelCraft

struct ComputerUseToolTests {

    @Test func typeTextSchemaMatchesItsDecodableInput() throws {
        let function = try #require(
            ComputerUseTool.typeText.schema["function"] as? [String: any Sendable]
        )
        let parameters = try #require(
            function["parameters"] as? [String: any Sendable]
        )
        let properties = try #require(
            parameters["properties"] as? [String: any Sendable]
        )
        let required = try #require(parameters["required"] as? [String])

        #expect(properties["appID"] != nil)
        #expect(properties["text"] != nil)
        #expect(properties["appIdentifier"] == nil)
        #expect(Set(required).isSuperset(of: ["appID", "index", "text"]))

        let data = Data(#"{"appID":"com.apple.TextEdit","index":2,"text":"ModelCraft"}"#.utf8)
        let input = try JSONDecoder().decode(TypeTextInput.self, from: data)
        #expect(input.appID == "com.apple.TextEdit")
        #expect(input.index == 2)
        #expect(input.text == "ModelCraft")
    }

    @Test func modifierNamesMapToTheRequestedFlags() {
        let flags = ComputerUseTool.modifierFlags(
            for: ["command", "shift", "option", "control"]
        )

        #expect(flags.contains(.maskCommand))
        #expect(flags.contains(.maskShift))
        #expect(flags.contains(.maskAlternate))
        #expect(flags.contains(.maskControl))
    }

    @Test func elementPrefersItsAccessibilityTitle() {
        #expect(
            Element.displayTitle(
                title: "Save",
                description: "Toolbar item",
                help: "Save the document"
            ) == "Save"
        )
        #expect(
            Element.displayTitle(
                title: "  ",
                description: "Search field",
                help: "Enter a query"
            ) == "Search field"
        )
    }

    @Test func attachingChildrenPreservesTheHierarchy() {
        let root = Element(
            role: kAXWindowRole,
            actions: [],
            uiElment: AXUIElementCreateSystemWide()
        )
        let child = Element(
            role: kAXButtonRole,
            actions: [kAXPressAction],
            attributes: ["enabled": .bool(true), "title": .string("Continue")],
            uiElment: AXUIElementCreateSystemWide()
        )

        root.attach(children: [child])
        child.index = 0

        #expect(child.parent === root)
        #expect(child.accessibilityPath == "/AXButton(title=Continue)")
        #expect(root.getActionableElmenets().first?.contains("path=/AXButton(title=Continue)") == true)
    }

    @Test func editableTextAreasAreExposedAsInteractive() {
        let textArea = Element(
            role: kAXTextAreaRole,
            actions: [],
            attributes: ["enabled": .bool(true), "editable": .bool(true)],
            uiElment: AXUIElementCreateSystemWide()
        )

        #expect(textArea.interactive)
    }

    @Test func screenCoordinatesStayInTheQuartzTopLeftCoordinateSpace() {
        let point = CGPoint(x: 120, y: 240)

        #expect(ScreenControlManager.shared.screenToSystemPoint(point: point) == point)
    }
}
