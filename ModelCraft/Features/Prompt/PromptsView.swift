//
//  PromptsView.swift
//  ModelCraft
//
//  Created by Hongshen on 14/4/2024.
//

import SwiftUI
import SwiftData

struct PromptsView: View {
    
    @Query private var prompts: [Prompt] = []
    @State private var selections: Set<Prompt> = []
    @State private var selection: Prompt? = nil
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        List(prompts, selection: $selections) { prompt in
            ListCell(prompt).tag(prompt)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") {
                selection = selections.first
            }
            DeleteButton(style: .textOnly) { modelContext.delete(selections) }
        }
        .sheet(item: $selection) {
            selection = nil
        } content: { PromptEditionView(prompt: $0) }
        .toolbar(content: ToolbarItems)
    }
}

extension PromptsView {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItemGroup {
            Button("Add Prompt", systemImage: "plus") {
                selection = Prompt()
            }
        }
    }
    
    @ViewBuilder
    func ListCell(_ prompt: Prompt) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("/\(prompt.command)").font(.headline).lineLimit(1)
                Text(prompt.title).font(.subheadline).lineLimit(1)
            }
            Text(prompt.content).lineLimit(2).truncationMode(.middle)
        }
    }
}

#Preview {
    PromptsView()
        .modelContainer(for: [Prompt.self], inMemory: true)
}
