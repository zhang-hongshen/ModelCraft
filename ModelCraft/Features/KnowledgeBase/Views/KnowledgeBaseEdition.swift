//
//  KnowledgeBaseEdition.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 31/3/2024.
//

import SwiftUI
import SwiftData
import QuickLook


struct KnowledgeBaseEdition: View {
    
    @Bindable var konwledgeBase: KnowledgeBase
    @State private var fileImporterPresented: Bool = false
    @State private var selectedFiles: Set<URL> = []
    @State private var emojiPickerPresented = false
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.errorWrapper) private var errorWrapper
    
    var body: some View {
        VStack {
            Text("Knowledge Base").font(.headline)
            
            Button(action: {
                emojiPickerPresented = true
            }, label: {
                Image(systemName: konwledgeBase.icon)
            }).buttonStyle(.borderless).imageScale(.large)
            
            Form {
                TextField("Title", text: $konwledgeBase.title)
                
                FilesView()
                    .frame(minWidth: 200, minHeight: 100)
                    .safeAreaInset(edge: .bottom, content: OpearationButton)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .toolbar(content: ToolbarItems)
        .fileImporter(isPresented: $fileImporterPresented,
                      allowedContentTypes: [.data, .folder],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                konwledgeBase.files.formUnion(urls)
            case .failure(let error):
                errorWrapper.wrappedValue = ErrorWrapper(error: error,
                                                         guidance: "Please try again!")
            }
        }
    }
}

extension KnowledgeBaseEdition {
    
    @ToolbarContentBuilder
    func ToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: dismiss.callAsFunction)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
        }
    }
    
    
    @ViewBuilder
    func OpearationButton() -> some View {
        HStack(alignment: .center) {
            Button(action: {
                fileImporterPresented = true
            }, label: { Image(systemName: "plus") })
            
            
            Button(action: {
                konwledgeBase.files.subtract(selectedFiles)
            }, label: { Image(systemName: "minus") })
                .disabled(selectedFiles.isEmpty)
            
            Spacer()
        }
        .safeAreaPadding(Default.padding)
        .buttonStyle(.borderless)
        .background(.ultraThinMaterial)
    }
    
    @ViewBuilder
    func FilesView() -> some View {
        List(konwledgeBase.orderedFiles, selection: $selectedFiles) { url in
            ListCell(url).tag(url)
        }
        .listStyle(.inset)
    }
    
    @ViewBuilder
    func ListCell(_ url: URL) -> some View {
        Label {
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            FileThumbnail(url: url)
        }
    }
}

extension KnowledgeBaseEdition {
    
    func save() {
        dismiss()
        Task {
            await KnowledgaBaseModelActor(modelContainer: modelContext.container).insert(konwledgeBase)
        }
    }
    
}

#Preview {
    KnowledgeBaseEdition(konwledgeBase: KnowledgeBase())
}
