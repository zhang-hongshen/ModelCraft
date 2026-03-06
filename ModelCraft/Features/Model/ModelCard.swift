//
//  ModelCard.swift
//  ModelCraft
//
//  Created by Hongshen on 19/2/26.
//

import SwiftUI
import SwiftData

struct ModelCard: View {
    
    let model: ModelStoreModel
    
    @State private var isHovered = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore
    
    @Query private var downloadedModels: [LocalModel]
    @Query private var downloadTasks: [ModelTask]
    
    private var downloadState: DownloadState {
        if !downloadedModels.isEmpty {
            return .downloaded
        }
        if !downloadTasks.isEmpty {
            return .downloading
        }
        return .notDownloaded
    }
    
    enum DownloadState {
        case notDownloaded
        case downloading
        case stopped
        case downloaded
    }
    
    init(model: ModelStoreModel) {
        self.model = model
        let modelID = model.modelID
        self._downloadedModels = Query(
            filter: #Predicate<LocalModel> { $0.modelID == modelID }
        )
        let _type = TaskType.download.rawValue
        self._downloadTasks = Query(
            filter: #Predicate<ModelTask>{ $0.modelID == modelID && $0._type == _type },
            sort: \.createdAt
        )
    }
    
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 60, height: 60)
                
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
            }
            
            Text(model.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Group {
                switch downloadState {
                        
                case .notDownloaded:
                    Button {
                        createDownloadModelTask()
                    } label: {
                        Text("Download")
                    }.disabled(downloadState != .notDownloaded)
                    
                case .downloading:
                    ZStack {
                        ProgressView(value: downloadTasks.first?.fractionCompleted)
                            .progressViewStyle(.circular)
                        
                        Button {
                            stopDownloadTask()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .buttonStyle(.plain)
                    }
                case .stopped:
                    ZStack {
                        ProgressView(value: downloadTasks.first?.fractionCompleted)
                            .progressViewStyle(.circular)
                        
                        Button {
                            resumeDownloadTask()
                        } label: {
                            Image(systemName: "play")
                        }
                        .buttonStyle(.plain)
                    }
                case .downloaded:
                    Button {
                        
                    } label: {
                        Text("Downloaded")
                    }
                    .buttonStyle(.plain)
                }
            }.frame(height: 32)
            
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Layout.padding)
        .background(
            RoundedRectangle()
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(isHovered ? 0.2 : 0), radius: 5, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle()
                .stroke(Color.accentColor.opacity(isHovered ? 0.5 : 0), lineWidth: 2)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

extension ModelCard {
    
    func createDownloadModelTask() {
        let type = TaskType.download.rawValue
        let modelID = model.modelID
        let descriptor = FetchDescriptor<ModelTask>(
            predicate: #Predicate { $0.modelID == modelID && $0._type == type }
        )
        if let count = try? modelContext.fetchCount(descriptor), count != 0 {
            return
        }
        modelContext.persist(ModelTask(modelId: model.modelID, type: .download))
    }
    
    func stopDownloadTask() {
        if let task = globalStore.runningTasks[model.modelID] {
            task.cancel()
            globalStore.runningTasks.removeValue(forKey: model.modelID)
        }
    }
    
    func resumeDownloadTask() {
        downloadTasks.first?.status = .new
    }
}
