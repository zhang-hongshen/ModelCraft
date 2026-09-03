//
//  MockData.swift
//  ModelCraft
//
//  Created by Hongshen on 18/5/26.
//

import Foundation
import SwiftData
import SwiftUI
import MLXLMCommon

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
    
    static let previews = [
        preview,
        Chat(title: "Tech Stack of ModelCraft", project: .preview)
    ]

    static let preview: Chat = {
        let chat = Chat(title: "Tool Call Workflow", project: .preview)
        let messages = [
            Message(
                role: .user,
                chat: chat,
                content: "Please update the project and generate a preview image."
            ),
            Message(
                role: .assistant,
                chat: chat,
                content: "I’ll inspect the relevant files first."
            ),
            Message(
                role: .tool,
                chat: chat,
                toolCall: ToolCall(function: .init(
                    name: ToolNames.readFile,
                    arguments: ["path": "Sources/App.swift"]
                )),
                toolCallResult: .success(content: [.text(TextContent(text: "import SwiftUI"))])
            ),
            Message(
                role: .tool,
                chat: chat,
                toolCall: ToolCall(function: .init(
                    name: ToolNames.writeFile,
                    arguments: ["path": "Sources/App.swift"]
                )),
                toolCallResult: .success()
            ),
            Message(
                role: .assistant,
                chat: chat,
                content: "The source file has been updated."
            ),
            Message(
                role: .tool,
                chat: chat,
                toolCall: ToolCall(function: .init(
                    name: ToolNames.textToImage,
                    arguments: ["prompt": "A quiet mountain landscape"]
                )),
                toolCallResult: CallToolResult(content: [
                    .resourceLink(ResourceLink(url: PreviewResources.png.url, mimeType: "image/png"))
                ])
            )
        ]
        chat.messages = messages
        return chat
    }()
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


extension SwiftData.ModelContainer {
    static var preview: SwiftData.ModelContainer = {
        let schema = Schema([
            Message.self, Chat.self, ModelTask.self,
            Project.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        do {
            return try SwiftData.ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create preview model container: \(error)")
        }
    }()
}


struct PreviewEnvironment: PreviewModifier {
    
    static func makeSharedContext() async throws -> SwiftData.ModelContainer {
        let container = try SwiftData.ModelContainer(for:
                                            Message.self, Chat.self, ModelTask.self,
                                           Project.self,
                                           configurations: .init(isStoredInMemoryOnly: true))
        
        let context = container.mainContext

        context.insert(Project.previews)
        context.insert(Chat.previews)
        context.insert(Message.previews)
        context.insert(ModelTask.previews)
        try context.save()
        return container
    }
    
    
    func body(content: Content, context: SwiftData.ModelContainer) -> some View {
        content
            .modelContainer(context)
            .environment(SpeechManager())
            .environment(GlobalStore())
            .environment(LocalModelStore(models: LocalModel.previews))
            .environment(UserSettings())
            .environment(STTService())
    }
}

extension PreviewTrait where T == Preview.ViewTraits {
    static var preview: Self {
        .modifier(PreviewEnvironment())
    }
}
