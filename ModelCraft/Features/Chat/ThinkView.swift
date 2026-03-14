//
//  ThinkView.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import SwiftUI

import MarkdownUI

struct ThinkView: View {
    
    @State var think: String
    @State private var isExpanded = false
    
    init(_ think: String) {
        self.think = think
        self.isExpanded = false
    }
    
    var body: some View {
        DisclosureGroup("Thinking", isExpanded: $isExpanded) {
            Markdown(think)
                .markdownTheme(.modelCraft)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
    
        }
    }
}
