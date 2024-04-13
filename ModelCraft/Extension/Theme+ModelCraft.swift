//
//  Theme+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 13/4/2024.
//
import SwiftUI
import MarkdownUI

extension Theme {
    
    /// A theme that mimics the modelCraft style.
    public static let modelCraft = Theme()
        .text {
            ForegroundColor(.text)
        }
        .link {
            ForegroundColor(.link)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: .em(0.8), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(2))
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.0625))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.88235))
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.07143))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.64706))
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.083335))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.41176))
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.09091))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.29412))
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.235295))
                .markdownMargin(top: .em(1.6), bottom: .zero)
                .markdownTextStyle {
                    FontWeight(.semibold)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.235295))
                .markdownMargin(top: .em(0.8), bottom: .zero)
        }
        .blockquote { configuration in
            configuration.label
                .relativePadding(length: .rem(0.94118))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        RoundedRectangle()
                            .fill(Color.asideNoteBackground)
                        RoundedRectangle()
                            .strokeBorder(Color.asideNoteBorder)
                    }
                }
                .markdownMargin(top: .em(1.6), bottom: .zero)
        }
        .code {
            BackgroundColor(Color.codeBackground)
        }
        .codeBlock { configuration in
            
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.333335))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.rem(0.88235))
                    }
                    .padding(.vertical, Default.padding)
                    .padding(.leading, Default.padding)
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Text(configuration.language ?? "").foregroundStyle(.secondary)
                    Spacer()
                    CopyButton {
                        Pasteboard.general.setString(configuration.content)
                    }.buttonStyle(.borderless)
                }
                .font(.subheadline)
                .padding(Default.padding)
                .background(.ultraThinMaterial)
            }
            .background(Color.codeBackground)
            .cornerRadius()
            .markdownMargin(top: .em(0.8), bottom: .zero)
        }
        .image { configuration in
            configuration.label
                .frame(maxWidth: .infinity)
                .markdownMargin(top: .em(1.6), bottom: .em(1.6))
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.8))
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.checkbox, Color.checkboxBackground)
                .imageScale(.small)
                .relativeFrame(minWidth: .em(1.5), alignment: .trailing)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(.horizontalBorders, color: .grid))
                .markdownMargin(top: .em(1.6), bottom: .zero)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.235295))
                .relativePadding(length: .rem(0.58824))
        }
        .thematicBreak {
            Divider()
                .overlay(Color.grid)
                .markdownMargin(top: .em(2.35), bottom: .em(2.35))
        }
}


extension Color {
    fileprivate static let text = Color(
        light: Color(rgba: 0x1d1d_1fff), dark: Color(rgba: 0xf5f5_f7ff)
    )
    fileprivate static let secondaryLabel = Color(
        light: Color(rgba: 0x6e6e_73ff), dark: Color(rgba: 0x8686_8bff)
    )
    fileprivate static let link = Color(
        light: Color(rgba: 0x0066_ccff), dark: Color(rgba: 0x2997_ffff)
    )
    fileprivate static let asideNoteBackground = Color(
        light: Color(rgba: 0xf5f5_f7ff), dark: Color(rgba: 0x3232_32ff)
    )
    fileprivate static let asideNoteBorder = Color(
        light: Color(rgba: 0x6969_69ff), dark: Color(rgba: 0x9a9a_9eff)
    )
    fileprivate static let codeBackground = Color(
        light: Color(rgba: 0xf5f5_f7ff), dark: Color(rgba: 0x3333_36ff)
    )
    fileprivate static let grid = Color(
        light: Color(rgba: 0xd2d2_d7ff), dark: Color(rgba: 0x4242_45ff)
    )
    fileprivate static let checkbox = Color(rgba: 0xb9b9_bbff)
    fileprivate static let checkboxBackground = Color(rgba: 0xeeee_efff)
}
