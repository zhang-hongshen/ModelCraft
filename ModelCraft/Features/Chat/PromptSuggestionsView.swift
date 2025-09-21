//
//  1.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/23/25.
//

import SwiftUI

struct PromptSuggestionsView: View {
    @State var minWidth: CGFloat
    var onTapPromptCard: (PromptSuggestion) -> Void = { _ in }
    
    @State private var columns: [GridItem] = []
    @State private var promptSuggestions: [PromptSuggestion] = Array(PromptSuggestion.examples().shuffled().prefix(4))
    private let promptCardWidth: CGFloat = 250
    private let promptCardHorizontalSpacing: CGFloat = 20
    
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .center) {
                    MessageRole.assistant.icon
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 200)
                    
                    Text("How can I help you today ?").font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    
                    LazyVGrid(columns: columns) {
                        ForEach(promptSuggestions) { prompt in
                            PromptCard(prompt: prompt, width: promptCardWidth)
                                .onTapGesture {
                                    onTapPromptCard(prompt)
                                }
                        }
                    }
                }
            }
            .contentMargins(0, for: .scrollIndicators)
            .onChange(of: proxy.size.width, initial: true) {
                let count = Int(proxy.size.width / minWidth)
                withAnimation {
                    columns = Array(repeating: .init(.fixed(promptCardWidth),
                                                     spacing: promptCardHorizontalSpacing,
                                                     alignment: .top),
                                    count: count)
                }
            }
        }
    }
}

#Preview {
    PromptSuggestionsView(minWidth: 270)
}
