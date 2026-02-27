//
//  ChatInputView.swift
//  ModelCraft
//
//  Created by Hongshen on 10/11/25.
//

import SwiftUI

struct ChatInputView: View {
    
    @State var chat: Chat?
    @Binding var draft: Message
    var onSubmit: () -> Void
    var onStop: () -> Void
    var onUploadImages: ([URL]) -> Void
    
    @State private var fileImporterPresented = false
    
    @Environment(GlobalStore.self) private var globalStore
    
    var body: some View {
        MessageEditor()
            .safeAreaPadding()
            .background(.regularMaterial)
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    onUploadImages(urls)
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
            
            if !draft.images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .center) {
                        ForEach(draft.images, id: \.self) { data in
                            ImageView(data: data) {
                                draft.images.removeAll { $0 == data }
                            }.frame(height: 80)
                        }
                    }
                }
            }
            
            
            TextField("", text: $draft.content, axis: .vertical)
                .lineLimit(1...5)
                .font(.title3)
                .textFieldStyle(.plain)
            
            HStack(alignment: .bottom) {
                UploadImageButton()
                Spacer()
                Group {
                    if chat?.sortedMessages.last?.status == .generating {
                        StopGenerateMessageButton()
                    } else {
                        SubmitMessageButton()
                    }
                }
            }.font(.title2)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding()
        .overlay {
            RoundedRectangle().fill(.clear).stroke(.primary, lineWidth: 1)
        }
    }
    
    @ViewBuilder
    func UploadImageButton() -> some View {
        Button {
            fileImporterPresented = true
        } label: {
            Image(systemName: "plus")
        }
    }
    
    @ViewBuilder
    func StopGenerateMessageButton() -> some View {
        Button(action: onStop) {
            Image(systemName: "stop.circle.fill")
        }
    }
    
    @ViewBuilder
    func SubmitMessageButton() -> some View {
        let disabled = globalStore.selectedModel == nil || draft.content.isEmpty
        Button(action: onSubmit) {
            Image(systemName: "arrow.up.circle.fill")
        }
        .tint(disabled ? .secondary : .accentColor)
        .disabled(disabled)
        .keyboardShortcut(.return, modifiers: .command)
    }
}

#Preview {
    ChatInputView(
        chat: Chat(),
        draft: .constant(Message(chat: Chat())),
        onSubmit: {},
        onStop: {},
        onUploadImages: {_ in })
}
