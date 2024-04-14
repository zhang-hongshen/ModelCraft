//
//  PromptSearchView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 14/4/2024.
//

import SwiftUI
import SwiftData

struct PromptSearchView: View {
    
    @Binding var searchText: String
    private let onSelectPrompt: (String) -> Void
    
    @Query private var prompts: [Prompt] = []
    @State private var selection: Prompt? = nil
    
    private var filteredPrompts: [Prompt] {
        guard searchText.hasPrefix("/") else { return [] }
        let command = searchText[String.Index(utf16Offset: 1, in: searchText)...]
        if command.isEmpty { return prompts }
        return prompts.filter({ $0.command.hasPrefix(command)})
    }
    
    private var defaultSelection: Prompt? { filteredPrompts.first }
    
    private var preSelection: Prompt? {
        guard let selection else { return defaultSelection }
        return filteredPrompts.element(before: selection)
    }
    
    private var nextSelection: Prompt? {
        guard let selection else { return defaultSelection }
        guard let element = filteredPrompts.element(after: selection) else { return filteredPrompts.first }
        return element
    }
    
    init(searchText: Binding<String>, onSelectPrompt: @escaping (String) -> Void = { _ in}) {
        self._searchText = searchText
        self.onSelectPrompt = onSelectPrompt
    }
    
    var body: some View {
        if filteredPrompts.isEmpty {
            EmptyView()
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading) {
                    ForEach(filteredPrompts) { prompt in
                        Button {
                            onSelectPrompt(prompt.content)
                        } label: {
                            HStack {
                                Text("/\(prompt.command)").font(.headline)
                                Text(prompt.title).font(.subheadline)
                                Spacer()
                            }
                            .padding(Default.padding)
                            .cornerRadius()
                        }
                        .background {
                            if selection == prompt {
                                RoundedRectangle().fill(.thinMaterial)
                            }
                        }
                        .onHover { isHovering in
                            if isHovering {
                                selection = prompt
                            }
                        }
                        .id(prompt.id)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.vertical, Default.padding)
                .padding(.trailing, Default.padding)
            }
            .scrollIndicators(.never, axes: .vertical)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow, .return]) { keyPress in
                keyAction(keyPress.key)
            }
            .safeAreaInset(edge: .leading) {
                Text("💡").padding(.leading, Default.padding)
            }
            .background(.ultraThinMaterial)
        }
    }
}
extension PromptSearchView {
    
    func keyAction(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .upArrow: selection = preSelection
        case .downArrow: selection = nextSelection
        case .return: if let selection { onSelectPrompt(selection.content) }
        default: return .ignored
        }
        return .handled
    }
}

#Preview {
    PromptSearchView(searchText: .constant(""))
}
