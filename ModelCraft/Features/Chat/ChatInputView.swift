//
//  ChatInputView.swift
//  ModelCraft
//
//  Created by Hongshen on 10/11/25.
//

import SwiftUI
import UniformTypeIdentifiers

struct ChatInputView<Content: View>: View {
    
    @Bindable var userInput: Message
    var trailing: () -> Content
    
    @State private var fileImporterPresented = false
    @Environment(GlobalStore.self) private var globalStore
    
    init(
        userInput: Message,
        @ViewBuilder trailing: @escaping () -> Content
    ) {
        self._userInput = Bindable(userInput)
        self.trailing = trailing
    }
    
    var body: some View {
        MessageEditor()
            .safeAreaPadding()
            .background(.ultraThinMaterial)
            .onDrop(of: [.image, .movie], isTargeted: nil, perform: handleDrop)
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.image, .movie],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    userInput.attachments.append(contentsOf: urls)
                case .failure(let error):
                    debugPrint(error.localizedDescription)
                }
            }
    }
}

extension ChatInputView {
    
    @ViewBuilder
    func MessageEditor() -> some View {
        VStack(alignment: .leading) {
            
            if !userInput.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .center) {
                        ForEach(userInput.attachments, id: \.self) { url in
                            AttachmentView(
                                url: url,
                                onDelete: { userInput.attachments.removeAll { $0 == url }}
                            ).frame(height: 70)
                        }
                    }
                }
            }
            
            
            TextField("Type Anything", text: $userInput.content, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .onDrop(of: [.image, .movie], isTargeted: nil, perform: handleDrop)
            
            HStack(alignment: .bottom) {
                UploadButton()
                Spacer()
                trailing()
            }.font(.title2)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding()
        .background(
            RoundedRectangle().fill(.background)
        )
        .overlay {
            RoundedRectangle().stroke(.separator.opacity(0.7), lineWidth: 0.5)
        }
    }
    
    @ViewBuilder
    func UploadButton() -> some View {
        Button {
            fileImporterPresented = true
        } label: {
            Image(systemName: "plus")
        }
    }
    
    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if providers.isEmpty {
            return false
        }
        for provider in providers {
            provider.loadObject(ofClass: URL.self) { url, error in
                if let url = url {
                    userInput.attachments.append(url)
                } else if let error = error {
                    print("Error: \(error.localizedDescription)")
                }
            }
        }
        return true
    }
    
}

#Preview {
    ChatInputView(
        userInput: Message(chat: Chat()),
        trailing: {})
    .environment(GlobalStore())
}
