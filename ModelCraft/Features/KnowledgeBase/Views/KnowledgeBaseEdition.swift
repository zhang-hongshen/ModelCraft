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
                
                ContentView()
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
                urls.forEach { konwledgeBase.files.insert($0) }
            case .failure(let error):
                print(error.localizedDescription)
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
    func ContentView() -> some View {
        List(selection: $selectedFiles) {
            ForEach(konwledgeBase.orderedFiles, id: \.self) { url in
                FileItem(url: url).tag(url)
            }
        }
        .listStyle(.inset)
    }
}

extension KnowledgeBaseEdition {
    
    func save() {
        dismiss.callAsFunction()
        do {
            let id = konwledgeBase.id
            let exist = try modelContext.fetchCount(FetchDescriptor<KnowledgeBase>(
                predicate: #Predicate { $0.id == id },
                sortBy: [.init(\.createdAt)]
            )) > 0
            if !exist { modelContext.insert(konwledgeBase) }
        } catch {
            print("fetchCount error, \(error.localizedDescription)")
        }
    }
    
}

#Preview {
    KnowledgeBaseEdition(konwledgeBase: KnowledgeBase())
}
