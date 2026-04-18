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
                    ModelInfo()
                    DownloadActionView()
                }
            case .list:
                HStack(alignment: .center) {
                    ModelIcon()
                    ModelInfo()
                    Spacer()
                    DownloadActionView()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(
            RoundedRectangle()
                .fill(.background)
                .shadow(color: .primary.opacity(isHovered ? 0.2 : 0), radius: 5, x: 0, y: 2)
                .overlay(
                    RoundedRectangle()
                        .stroke(Color.secondary.opacity(isHovered ? 0.5 : 0), lineWidth: 1)
                )
        )
        .offset(y: isHovered ? -2 : 0)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isHovered = hovering
            }
        }
    }
}

extension ModelCard {
    
    @ViewBuilder
    func ModelIcon(size: CGFloat = 56) -> some View {
        RoundedRectangle()
            .fill(.quaternary.opacity(0.4))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: size * 0.45, weight: .light))
                    .foregroundStyle(.primary.opacity(0.8))
            }
    }
    
    @ViewBuilder
    func ModelInfo() -> some View {
        VStack(alignment: viewMode == .grid ? .center : .leading, spacing: 4) {
            HStack {
                Text(model.displayName)
                    .font(.title3)
                    .fontDesign(.rounded)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                if model.isVLM {
                    Text("Vision")
                        .font(.caption2)
                        .padding(Layout.padding)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
            
            if let size = model.sizeInBytes {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
                        .font(.title)
                }
                .disabled(downloadState != .notDownloaded)
                
            case .downloading:
                if let fractionCompleted = downloadTasks.first?.fractionCompleted {
                    ProgressView(value: fractionCompleted)
                        .progressViewStyle(.circular)
                        .overlay {
                            Button {
                                stopDownloadTask()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 16, weight: .bold))
                            }
                        }
                } else {
                    ProgressView()
                }
                
            case .stopped:
                ProgressView(value: downloadTasks.first?.fractionCompleted)
                    .progressViewStyle(.circular)
                    .overlay {
                        Button {
                            resumeDownloadTask()
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
            case .downloaded:
                Text("Downloaded")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(Layout.padding)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
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
        modelContext.persist(ModelTask(modelId: model.id, totalUnitCount: model.sizeInBytes, type: .download))
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
