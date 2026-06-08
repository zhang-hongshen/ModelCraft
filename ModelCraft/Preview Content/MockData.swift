//
//  MockData.swift
//  ModelCraft
//
//  Created by Hongshen on 18/5/26.
//

import Foundation
import SwiftData
import SwiftUI


enum PreviewResources: String, CaseIterable, Identifiable {
    
    case mov, mp3, pdf, wav, png
    
    var id: Self { self }    

    var url: URL {
        guard let url = Bundle.main.url(forResource: "example", withExtension: self.rawValue) else {
            fatalError("Can not find the file: example.\(self.rawValue)")
        }
        return url
    }
}




extension Message {
    static let preview = Message(role: .user,
                                 chat: .preview,
                                 content:"First...")
    
    static let previews = [
        preview,
        Message(role: .assistant,
                chat: .preview,
                content: "First...")
    ]
}

extension Chat {
    
    static let preview = Chat(title: "Introduce ModelCraft", project: .preview)
    
    static let previews = [
        preview,
        Chat(title: "Tech Stack of ModelCraft", project: .preview)
    ]
}

extension Project {
    
    static let preview = Project(title: "ModelCraft", files: [PreviewResources.mov.url, PreviewResources.pdf.url, PreviewResources.mp3.url])
    
    static let previews = [
        preview,
        Project(title: "ModelCraft UI", files: [PreviewResources.png.url, PreviewResources.mp3.url, PreviewResources.pdf.url]),
    ]
}


extension ModelTask {
    
    static let preview = ModelTask(modelId: "download/running", fractionCompleted: 0.9, status: .running, type: .download)
    
    static let previews = [
        ModelTask(modelId: "download/new", status: .new, type: .download),
        preview,
        ModelTask(modelId: "download/stopped", fractionCompleted: 0.5, status: .stopped, type: .download),
        ModelTask(modelId: "download/failed", status: .failed, type: .download),
        ModelTask(modelId: "delete/running", type: .delete)
    ]
    
}

extension LocalModel {
    
    static let preview = LocalModel(id: "1", size: 1000000)
    
    static let previews = [
        preview,
        LocalModel(id: "2", size: 1000000)
    ]
    
}


extension ModelContainer {
    
//    @MainActor
    static var preview: ModelContainer = {
        let schema = Schema([
            Message.self, Chat.self, ModelTask.self,
            Project.self, LocalModel.self,
        ])

        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        
        do {
            let container = try ModelContainer(for: schema, configurations: [modelConfiguration])
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    
}


struct PreviewEnvironment: PreviewModifier {
    
    static func makeSharedContext() async throws -> ModelContainer {
        let container = try ModelContainer(for:
                                            Message.self, Chat.self, ModelTask.self,
                                           Project.self, LocalModel.self,
                                           configurations: .init(isStoredInMemoryOnly: true))
        
        let context = container.mainContext

        context.insert(Project.previews)
        context.insert(Chat.previews)
        context.insert(Message.previews)
        context.insert(ModelTask.previews)
        context.insert(LocalModel.previews)

        try context.save()
        return container
    }
    
    
    func body(content: Content, context: ModelContainer) -> some View {
        content
            .modelContainer(context)
            .environment(SpeechManager())
            .environment(GlobalStore())
            .environment(UserSettings())
            .environment(STTService())
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    static var preview: Self {
        .modifier(PreviewEnvironment())
    }
}
