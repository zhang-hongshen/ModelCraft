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
    @State private var infoPresented = false
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.speechSynthesizer) private var speechSynthesizer
    
    private let imageHeight: CGFloat = 200
    
    private let columns = Array.init(repeating: GridItem(.flexible()), count: 4)
    
    private var splashTheme: Splash.Theme {
        switch self.colorScheme {
        case .dark:
            return .sundellsColors(withFont: .init(size: 16))
        default:
            return .sunset(withFont: .init(size: 16))
        }
    }
    
    var body: some View {
        if message.role == .assistant {
            AssistantMessageView()
        } else {
            UserMessageView()
        }
    }

}

// MARK: Common Message

extension MessageView {
    
    @ViewBuilder
    func CommonButtons() -> some View {
        CopyButton {
            Pasteboard.general.setString(message.content)
        }
    }
    
    @ViewBuilder
    func MessageImageView() -> some View {
        LazyVGrid(columns: columns){
            ForEach(message.images, id: \.self) { data in
                ImageLoader(data: data, contentMode: .fit)
                    .frame(height: imageHeight)
                    .cornerRadius()
            }
        }
    }
    
    @ViewBuilder
    func MessageContentView() -> some View {
        Markdown(message.status != .failed ? message.content : "Failed.Please try again later.")
            .markdownTheme(.modelCraft)
            .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
            .textSelection(.enabled)
            .multilineTextAlignment(.leading)
    }

}

// MARK: User Message

extension MessageView {
    
    @ViewBuilder
    func UserMessageView() -> some View {
        HStack(alignment: .top) {
            Spacer()
            VStack(alignment: .trailing) {
                Text(message.createdAt.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                
                if !message.content.isEmpty {
                    MessageContentView()
                        .padding()
                        .background {
                            RoundedRectangle().fill(.quaternary)
                        }
                        .contextMenu {
                            UserButtons()
                        }
                    
                }
                
                if !message.images.isEmpty {
                    MessageImageView()
                }
                
                HStack(content: UserButtons)
                    .buttonStyle(.borderless)
                    .opacity(isHovering ? 1 : 0)
                    .frame(height: 16)
                
            }
            .onHover(perform: { isHovering = $0 })
        }
    }
    
    @ViewBuilder
    func UserButtons() -> some View {
        HStack {
            CommonButtons()
        }
    }
}


// MARK: Assistant Message

extension MessageView {
    @ViewBuilder
    func AssistantMessageView() -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(message.createdAt.formatted())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(isHovering ? 1 : 0)
                
                switch message.status {
                case .new:
                    ActivityIndicatorView(isVisible: .constant(true),
                                          type: .opacityDots())
                    .frame(width: 30, height: 10)
                default:
                    if !message.content.isEmpty {
                        MessageContentView()
                            .contextMenu {
                                AssistantButtons()
                            }
                    }
                }
                
                if !message.images.isEmpty {
                    MessageImageView()
                }
                
                HStack(content: AssistantButtons)
                    .buttonStyle(.borderless)
                    .opacity(isHovering ? 1 : 0)
                    .frame(height: 16)
                
            }
            .onHover(perform: { isHovering = $0 })
            Spacer()
        }
    }
    
    @ViewBuilder
    func AssistantButtons() -> some View {
        HStack(alignment: .center) {
            CommonButtons()
            
            if speechSynthesizer.isSpeaking {
                Button {
                    speechSynthesizer.stop()
                } label: {
                    Image(systemName: "stop.circle")
                }
            } else {
                Button {
                    speechSynthesizer.speak(message.content)
                } label: {
                    Image(systemName: "speaker.wave.2")
                }.disabled(speechSynthesizer.isSpeaking)
            }
            
            
            Button {
                infoPresented = true
            } label: {
                Image(systemName: "info.circle")
            }.popover(isPresented: Binding(
                get: { infoPresented && isHovering },
                set: { infoPresented = $0 }
            ), arrowEdge: .top) {
                Form {
                    if let totalDuration = message.totalDuration {
                        LabeledContent("Total cost:",
                                       value: Duration.nanoseconds(totalDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let loadDuration = message.loadDuration {
                        LabeledContent("Loading model cost:",
                                       value: Duration.nanoseconds(loadDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let promptEvalDuration = message.promptEvalDuration {
                        LabeledContent("Evaluating prompt cost:",
                                       value: Duration.nanoseconds(promptEvalDuration).formatted(.units(allowed: [.seconds])))
                    }
                    if let evalDurationInSecond = message.evalDurationInSecond {
                        LabeledContent("Generating response cost:",
                                       value: Duration.seconds(evalDurationInSecond).formatted(.units(allowed: [.seconds])))
                    }
                    if let tokenPerSecond = message.tokenPerSecond {
                        LabeledContent("Token per second:",
                                       value: "\(tokenPerSecond.formatted(.number.precision(.fractionLength(2))))/s")
                    }
                }.padding()
            }
            
        }
        
    }
}
