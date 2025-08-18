//
//  TextOutputFormat.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import SwiftUI

import Splash

struct TextOutputFormat: OutputFormat {
    private let theme: Theme
    
    init(theme: Theme) {
        self.theme = theme
    }
    
    func makeBuilder() -> Builder {
        Builder(theme: self.theme)
    }
}

extension TextOutputFormat {
    
    struct Builder: OutputBuilder {
        private let theme: Theme
        private var accumulatedText: [Text]
        
        fileprivate init(theme: Theme) {
            self.theme = theme
            self.accumulatedText = []
        }
        
        mutating func addToken(_ token: String, ofType type: TokenType) {
            let color = self.theme.tokenColors[type] ?? self.theme.plainTextColor
            self.accumulatedText.append(Text(token).foregroundStyle(Color(cgColor: color.cgColor)))
        }
        
        mutating func addPlainText(_ text: String) {
            self.accumulatedText.append(
                Text(text).foregroundStyle(Color(cgColor: self.theme.plainTextColor.cgColor))
            )
        }
        
        mutating func addWhitespace(_ whitespace: String) {
            self.accumulatedText.append(Text(whitespace))
        }
        
        func build() -> Text {
            self.accumulatedText.reduce(Text(""), +)
        }
    }
    
}
