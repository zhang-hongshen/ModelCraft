//
//  ChatInputView.swift
//  ModelCraft
//
//  Created by Hongshen on 10/11/25.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatInputView<Content: View>: View {
    
    @Bindable var userInput: Message
    var trailing: () -> Content
    
    @State private var fileImporterPresented = false
    @State private var photosPickerPresented = false
    @Environment(GlobalStore.self) private var globalStore
    
    @State private var selectedImages: [PhotosPickerItem] = [] {
        didSet {
            var newFiles: [URL] = []
            for image in selectedImages {
                Task {
                    if let url = try await image.loadTransferable(type: URL.self) {
                        newFiles.append(url)
                    }
                }
            }
            userInput.files.append(contentsOf: newFiles)
        }
    }
    
    init(
        userInput: Message,
        @ViewBuilder trailing: @escaping () -> Content
    ) {
        self._userInput = Bindable(userInput)
        self.trailing = trailing
    }
    
    var body: some View {
        MainView()
            .dropDestination(for: URL.self){ items, location in
                userInput.addFiles(items)
                return true
            }
            .fileImporter(isPresented: $fileImporterPresented,
                          allowedContentTypes: [.image, .movie],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    userInput.addFiles(urls)
                case .failure(let error):
                    debugPrint(error.localizedDescription)
                }
            }
            .photosPicker(isPresented: $photosPickerPresented, selection: $selectedImages)
    }
}

extension ChatInputView {
    
    @ViewBuilder
    func MainView() -> some View {
        VStack(alignment: .leading) {
            
            if !userInput.files.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .center) {
                        ForEach(userInput.files, id: \.self) { url in
                            MessageFileView(
                                url: url,
                                onDelete: { userInput.removeFiles([url])}
                            ).frame(height: 70)
                        }
                    }
                }
            }
            
            ViewThatFits {
                
                HStack(alignment: .center) {
                    UploadButton()
                    TextField("Type Anything", text: $userInput.content, axis: .vertical)
                        .lineLimit(1)
                        .textFieldStyle(.plain)
                    trailing()
                }
                
                VStack {
                    TextField("Type Anything", text: $userInput.content, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                    
                    HStack(alignment: .center) {
                        UploadButton()
                        Spacer()
                        trailing()
                    }
                }
            }
            
            
        }
        .padding()
        .background(
            RoundedRectangle().fill(.background)
        )
    }
    
    @ViewBuilder
    func UploadButton() -> some View {
        Menu {
            Button {
                fileImporterPresented = true
            } label: {
                Label("Files", systemImage: "doc.badge.plus")
            }
            
            Button {
                photosPickerPresented = true
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle.angled")
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .help("Add Files")
    }
}

#Preview(traits: .preview) {
    ChatInputView(
        userInput: Message(chat: .preview),
        trailing: {})
}
