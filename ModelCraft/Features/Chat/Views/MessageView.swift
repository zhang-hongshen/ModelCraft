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
import ActivityIndicatorView

struct MessageView: View {
    
    var message: Message
    
    @State private var copied = false
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
        HStack(alignment: .top) {
            message.role.icon.resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 25)
            
            VStack(alignment: .leading) {
                
                Text(message.role.localizedName)
                    .font(.headline)
                
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
                if message.done {
                    HStack {
                        CopyButton()
                        if message.role == .assistant {
                            AssistantButtons()
                        }
                    }.buttonStyle(.borderless)
                }
#endif
            }
        }
    }
    
    @ViewBuilder
    static func UserWaitingForResponseView() -> some View {
        HStack(alignment: .top) {
            MessageRole.assistant.icon.resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 25)
            VStack(alignment: .leading) {
                Text(MessageRole.assistant.localizedName)
                    .font(.headline)
                ActivityIndicatorView(isVisible: .constant(true),
                                      type: .opacityDots())
                .frame(width: 30, height: 10)
            }
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
        }
    }
}
