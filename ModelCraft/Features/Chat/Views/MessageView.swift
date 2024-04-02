//
//  MessageView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import SwiftUI
import AVFoundation
import NaturalLanguage

import MarkdownUI
import Splash

struct MessageView: View {
    
    var message: Message
    
    @State private var copied = false
    @State private var isEditing = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.speechSynthesizer) private var speechSynthesizer
    
    private let imageHeight: CGFloat = 200
#if os(macOS)
    private let columns = Array.init(repeating: GridItem(.flexible()), count: 4)
#endif
    
    private var splashTheme: Splash.Theme {
      switch self.colorScheme {
      case .dark:
          return .sundellsColors(withFont: .init(size: 16))
      default:
          return .sunset(withFont: .init(size: 16))
      }
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .center) {
                message.role.icon.resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 25)
                Text(message.role.localizedName)
                    .font(.headline)
            }
            
            Markdown(message.content)
                .markdownTheme(.docC)
                .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .contextMenu {
                    if message.role == .assistant {
                        AssistantButtons()
                    }
                }
            
            LazyVGrid(columns: columns, spacing: 10){
                ForEach(message.images, id: \.self) { data in
                    if let image = PlatformImage(data: data) {
                        Image(data: data)?.resizable()
                            .allowedDynamicRange(.high)
                            .interpolation(.none)
                            .aspectRatio(image.aspectRatio, contentMode: .fit)
                            .frame(height: imageHeight)
                            .cornerRadius()
                    }
                }
            }
            
#if os(macOS)
            HStack {
                CopyButton()
                if message.role == .assistant {
                    AssistantButtons()
                } else {
                    if !isEditing {
                        Button("", systemImage: "square.and.pencil", action: { isEditing = true })
                            .help("Edit")
                    } else {
                        Button("Submit", action: {})
                        Button("Cancel", role: .cancel, action: { isEditing = false} )
                    }
                }
            }.buttonStyle(.borderless)
#endif
        }
    }
}

extension MessageView {
    
    @ViewBuilder
    func CopyButton() -> some View {
        Button("Copy", systemImage: copied ? "checkmark" : "clipboard") {
            Pasteboard.general.setString(message.content)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                copied = false
            }
        }.help("Copy")
    }
    
    
    @ViewBuilder
    func AssistantButtons() -> some View {
        Button("Read", systemImage: "mic") {
            speechSynthesizer.speak(message.content)
        }.help("Good Response")
        Button("Good", systemImage: "hand.thumbsup", action: {})
            .help("Good Response")
        Button("Bad", systemImage: "hand.thumbsdown", action: {})
            .help("Bad Response")
    }
}
