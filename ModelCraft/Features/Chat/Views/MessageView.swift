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
        HStack(alignment: .top) {
            
            message.role.icon.resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 25)
            
            VStack(alignment: .leading) {
                
                HStack {
                    Text(message.role.localizedName)
                        .font(.title3)
                    
                    if isHovering {
                        Text(message.createdAt.formatted())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                }
                
                switch message.status {
                case .new:
                    ActivityIndicatorView(isVisible: .constant(true),
                                          type: .opacityDots())
                    .frame(width: 30, height: 10)  
                default:
                    if message.content.isEmpty {
                        EmptyView()
                    } else {
                        Markdown(message.content)
                            .markdownTheme(.modelCraft)
                            .markdownCodeSyntaxHighlighter(.splash(theme: self.splashTheme))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.leading)
                            .contextMenu {
                                Buttons()
                            }
                    }
                }
                
                if !message.images.isEmpty {
                    LazyVGrid(columns: columns){
                        ForEach(message.images, id: \.self) { data in
                            ImageLoader(data: data, contentMode: .fit)
                                .frame(height: imageHeight)
                                .cornerRadius()
                        }
                    }
                }
                
                Group {
                    if isHovering {
                        HStack(content: Buttons).buttonStyle(.borderless)
                    } else {
                        Color.clear
                    }
                }.frame(height: 20)
                
            }
            .onHover(perform: { isHovering = $0 })
        }
    }
    
    @ViewBuilder
    func Buttons() -> some View {
        CopyButton {
            Pasteboard.general.setString(message.content)
        }
        if message.role == .assistant {
            AssistantButtons()
        }
    }

}

extension MessageView {
    
    @ViewBuilder
    func AssistantButtons() -> some View {
        HStack {
            
            Button("", systemImage: "mic") {
                speechSynthesizer.speak(message.content)
            }
            
            InfoButton {
                infoPresented = true
            }.popover(isPresented: $infoPresented, arrowEdge: .top) {
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
