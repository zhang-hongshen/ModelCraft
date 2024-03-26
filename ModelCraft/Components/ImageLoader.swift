//
//  ImageLoader.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import SwiftUI
import Kingfisher

struct ImageLoader<Content>: View where Content: View {
    
    @State private var url: URL? = nil
    @State private var data: Data? = nil
    @State private var aspectRatio: CGFloat? = nil
    @State private var contentMode: SwiftUI.ContentMode = .fit
    private var placeholder: () -> Content
    
    public init(url: URL?, aspectRatio: CGFloat? = nil, contentMode: SwiftUI.ContentMode = .fill,
                @ViewBuilder placeholder: @escaping () -> Content = { DefaultImageView() }) {
        self._url = State(wrappedValue: url)
        self.aspectRatio = aspectRatio
        self.contentMode = contentMode
        self.placeholder = placeholder
    }
    
    public init(data: Data?, aspectRatio: CGFloat? = nil, contentMode: SwiftUI.ContentMode = .fill,
                @ViewBuilder placeholder: @escaping () -> Content = { DefaultImageView() }) {
        self.url = nil
        self.aspectRatio = nil
        self.contentMode = contentMode
        self.placeholder = placeholder
        self.data = data
    }
    
    var body: some View {
        guard let data , let image = PlatformImage(data: data) else {
            return AnyView(
                KFImage(url)
                  .placeholder(placeholder)
                  .resizable()
                  .loadDiskFileSynchronously()
                  .cacheMemoryOnly()
                  .fade(duration: 0.25)
                  .onProgress { receivedSize, totalSize in  }
                  .onSuccess { result in }
                  .onFailure { error in }
                  .aspectRatio(aspectRatio, contentMode: contentMode)
            )
        }
        return AnyView(
            Image(data: data)?.resizable()
                .allowedDynamicRange(.high)
                .interpolation(.none)
                .aspectRatio(image.size.width / image.size.height, contentMode: contentMode))
    }
}
