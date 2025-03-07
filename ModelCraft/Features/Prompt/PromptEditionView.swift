//
//  PromptEditionView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 14/4/2024.
//

import SwiftUI

enum Field {
    case title, command, content
}

struct PromptEditionView: View {
    
    @Bindable var prompt: Prompt
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @FocusState private var focusedField: Field?
    
    var body: some View {
        Form {
            TextField("Title", text: $prompt.title)
                .focused($focusedField, equals: .title)
            
            LabeledContent("Command") {
                TextField(text: $prompt.command, prompt: Text("Shortcut")) {
                }.focused($focusedField, equals: .command)
            }
            
            LabeledContent("Content") {
                TextEditor(text: $prompt.content)
                    .focused($focusedField, equals: .content)
                    .frame(minHeight: 100)
            }
        }
        .safeAreaPadding()
        .toolbar(content: ToolbarItems)
        .background(.ultraThinMaterial)
        .frame(minWidth: 300)
    }
}

extension PromptEditionView {
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
                if prompt.title.isEmpty {
                    focusedField = .title
                    return
                } else if prompt.command.isEmpty {
                    focusedField = .command
                    return
                } else if prompt.content.isEmpty {
                    focusedField = .content
                    return
                }
                modelContext.persist(prompt)
                dismiss()
            }
        }
    }
}

#Preview {
    PromptEditionView(prompt: Prompt(title: "help me", 
                                     command: "help",
                                     content: "sda"))
}
