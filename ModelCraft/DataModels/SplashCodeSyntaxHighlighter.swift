//
//  SplashCodeSyntaxHighlighter.swift
//  ModelCraft
//
//  Created by Hongshen on 23/3/2024.
//
import SwiftUI

import MarkdownUI
import Splash

struct SplashCodeSyntaxHighlighter: CodeSyntaxHighlighter {
    private let syntaxHighlighter: SyntaxHighlighter<TextOutputFormat>
    
    init(theme: Splash.Theme) {
        self.syntaxHighlighter = SyntaxHighlighter(format: TextOutputFormat(theme: theme))
    }
    
    func highlightCode(_ content: String, language: String?) -> Text {
        guard language != nil else {
            return Text(content)
        }
        
        return self.syntaxHighlighter.highlight(content)
    }
}

extension CodeSyntaxHighlighter where Self == SplashCodeSyntaxHighlighter {
    static func splash(theme: Splash.Theme) -> Self {
        SplashCodeSyntaxHighlighter(theme: theme)
    }
}
