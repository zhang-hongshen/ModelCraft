//
//  MessageView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import SwiftUI
import MarkdownUI
import Splash

struct MessageView: View {
    
    var message: Message
    
    @Environment(\.colorScheme) private var colorScheme
    
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
                .padding()
                .background(.thinMaterial)
            
            LazyVGrid(columns: columns, spacing: 10){
                ForEach(message.images, id: \.self) { data in
                    if let image = PlatformImage(data: data) {
                        Image(data: data)?.resizable()
                            .allowedDynamicRange(.high)
                            .interpolation(.none)
                            .aspectRatio(image.aspectRatio, contentMode: .fit)
                            .frame(height: imageHeight)
                    }
                }
            }
        }
    }
}
