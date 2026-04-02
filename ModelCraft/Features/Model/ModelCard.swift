//
//  ModelCard.swift
//  ModelCraft
//
//  Created by Hongshen on 19/2/26.
//

import SwiftUI
import SwiftData

struct ModelCard: View {
    
    @State var model: ModelStoreModel
    @State var viewMode: ViewMode
    @State private var isHovered = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore
    
    @Query private var downloadedModels: [LocalModel]
    @Query private var downloadTasks: [ModelTask]
    
    private var downloadState: DownloadState {
        if !downloadedModels.isEmpty {
            return .downloaded
        }
        if let downloadTask = downloadTasks.first {
            if downloadTask.status == .stopped {
                return .stopped
            }
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
    
    init(model: ModelStoreModel, viewMode: ViewMode) {
        self.model = model
        self.viewMode = viewMode
        let modelID = model.id
        self._downloadedModels = Query(
            filter: #Predicate<LocalModel> { $0.id == modelID }
        )
        let _type = TaskType.download.rawValue
        self._downloadTasks = Query(
            filter: #Predicate<ModelTask>{ $0.modelID == modelID && $0._type == _type },
            sort: \.createdAt
        )
    }
    
    var body: some View {
        Group {
            switch viewMode {
            case .grid:
                VStack(spacing: 12) {
                    ModelIcon()
                    ModelName()
                    DownloadActionView()
                }
            case .list:
                HStack(alignment: .center) {
                    ModelIcon()
                    ModelName()
                    Spacer()
                    DownloadActionView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Layout.padding)
        .background(
            RoundedRectangle()
                .fill(.background)
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
    
    @ViewBuilder
    func ModelIcon() -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.1))
            .frame(width: 60, height: 60)
            .overlay {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30))
            }
    }
    
    @ViewBuilder
    func ModelName() -> some View {
        Text(model.displayName)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
    }
    
    @ViewBuilder
    func DownloadActionView() -> some View {
        Group {
            switch downloadState {
            case .notDownloaded:
                Button {
                    createDownloadModelTask()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(downloadState != .notDownloaded)
                
            case .downloading:
                ProgressView(value: downloadTasks.first?.fractionCompleted)
                    .progressViewStyle(.circular)
                    .progressViewStyle(.scaled)
                    .overlay {
                        Button {
                            stopDownloadTask()
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                    }
            case .stopped:
                ProgressView(value: downloadTasks.first?.fractionCompleted)
                    .progressViewStyle(.circular)
                    .progressViewStyle(.scaled)
                    .overlay {
                        Button {
                            resumeDownloadTask()
                        } label: {
                            Image(systemName: "play.fill")
                        }
                    }
            case .downloaded:
                Button {
                    
                } label: {
                    Text("Downloaded")
                }
            }
        }
        .font(.system(size: 20))
        .buttonStyle(.plain)
    }
    
}

extension ModelCard {
    
    func createDownloadModelTask() {
        let type = TaskType.download.rawValue
        let modelID = model.id
        let descriptor = FetchDescriptor<ModelTask>(
            predicate: #Predicate { $0.modelID == modelID && $0._type == type }
        )
        if let count = try? modelContext.fetchCount(descriptor), count != 0 {
            return
        }
        modelContext.persist(ModelTask(modelId: model.id, type: .download))
    }
    
    func stopDownloadTask() {
        if let runningTask = globalStore.runningTasks[model.id] {
            runningTask.cancel()
            globalStore.runningTasks.removeValue(forKey: model.id)
        }
    }
    
    func resumeDownloadTask() {
        downloadTasks.first?.status = .new
    }
}
