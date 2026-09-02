//
//  MarkdownRenderConfig+ModelCraft.swift
//  ModelCraft
//

import AppKit
import SwiftUI
import SwiftStreamingMarkdown

extension MarkdownRenderConfig {

    static let modelCraft: MarkdownRenderConfig = {
        let base = MarkdownRenderConfig.default
        let bodyFonts = textFonts(for: .body)
        let calloutFonts = textFonts(for: .callout)
        let captionFonts = textFonts(for: .caption1)
        let codeFonts = textFonts(for: .body, monospaced: true)
        let controlBackground = Color(nsColor: .controlBackgroundColor)
        let separator = Color(nsColor: .separatorColor)

        return MarkdownRenderConfig(
            shouldAnimateText: base.shouldAnimateText,
            blockQuoteStyle: .init(
                textFonts: bodyFonts,
                textColor: .secondary
            ),
            headingStyle: .init(
                h1Font: textFonts(for: .title1, weight: .semibold, boldWeight: .bold),
                h2Font: textFonts(for: .title2, weight: .semibold, boldWeight: .bold),
                h3Font: textFonts(for: .title3, weight: .semibold, boldWeight: .bold),
                h4Font: textFonts(for: .headline, weight: .semibold, boldWeight: .bold),
                h5Font: textFonts(for: .body, weight: .semibold, boldWeight: .bold),
                h6Font: textFonts(for: .body, weight: .medium, boldWeight: .semibold),
                textColor: .primary
            ),
            orderedListStyle: .init(
                textFonts: bodyFonts,
                textColor: .primary
            ),
            paragraphStyle: .init(
                textFonts: bodyFonts,
                textColor: .primary
            ),
            tableStyle: .init(
                textFonts: calloutFonts,
                headerTextColor: .primary,
                regularTextColor: .primary,
                headerBackgroundColor: controlBackground,
                borderColor: separator,
                actionButtonColor: .accentColor
            ),
            inlineStyle: .init(
                boldTextColor: .primary,
                linkTextFont: bodyFonts.normal,
                linkTextColor: .accentColor,
                linkUnderlineStyle: [],
                codeTextFont: codeFonts.normal,
                codeTextColor: .primary,
                codeBackgroundColor: controlBackground,
                codeUnderlineColor: separator
            ),
            textContextMenu: base.textContextMenu,
            citationConfig: .init(
                isEnabled: base.citationConfig.isEnabled,
                coder: base.citationConfig.coder,
                font: captionFonts.normal,
                textColor: .secondary,
                backgroundColor: controlBackground
            ),
            codeBlockConfig: .init(
                theme: .github,
                backgroundColor: controlBackground,
                foregroundColor: .secondary,
                codeTextFonts: codeFonts,
                chromeTextFonts: captionFonts
            ),
            blockSpacing: 12,
            textSelectionConfig: base.textSelectionConfig,
            thematicBreakColor: separator,
            imageConfig: base.imageConfig
        )
    }()

    private static func textFonts(
        for textStyle: NSFont.TextStyle,
        weight: NSFont.Weight = .regular,
        boldWeight: NSFont.Weight = .semibold,
        monospaced: Bool = false
    ) -> TextFonts {
        let pointSize = NSFont.preferredFont(forTextStyle: textStyle).pointSize
        let normal = font(ofSize: pointSize, weight: weight, monospaced: monospaced)
        let bold = font(ofSize: pointSize, weight: boldWeight, monospaced: monospaced)

        return TextFonts(
            normal: normal,
            italic: italic(normal),
            bold: bold,
            boldItalic: italic(bold),
            preferredLetterSpacing: nil,
            preferredLineHeight: nil
        )
    }

    private static func font(
        ofSize pointSize: CGFloat,
        weight: NSFont.Weight,
        monospaced: Bool
    ) -> NSFont {
        if monospaced {
            return NSFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
        }
        return NSFont.systemFont(ofSize: pointSize, weight: weight)
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFont(
            descriptor: font.fontDescriptor.withSymbolicTraits(.italic),
            size: font.pointSize
        ) ?? font
    }
}
