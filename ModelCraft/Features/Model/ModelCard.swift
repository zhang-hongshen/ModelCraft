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
    let sizeInBytes: Int64?
    let viewMode: ViewMode
    let downloadTask: ModelTask?
    @State private var isHovered = false
    
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore
    @Environment(LocalModelStore.self) private var localModelStore
    
    private var downloadState: DownloadState {
        if localModelStore.contains(model.id) {
            return .downloaded
        }
        if let downloadTask {
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
    
    var body: some View {
        Group {
            switch viewMode {
            case .grid:
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        ModelIcon(size: 40)
                        Spacer(minLength: 8)
                        DownloadActionView()
                    }
                    ModelName()
                        .lineLimit(2, reservesSpace: true)
                    ModelMetadata()
                }
            case .list:
                HStack(spacing: 12) {
                    ModelIcon(size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        ModelName()
                            .lineLimit(1)
                        ModelMetadata()
                    }
                    Spacer(minLength: 12)
                    DownloadActionView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(viewMode == .grid ? 14 : 12)
        .background(
            RoundedRectangle()
                .fill(.surface)
                .overlay(
                    RoundedRectangle()
                        .strokeBorder(.secondary.opacity(isHovered ? 0.4 : 0.12), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle())
        .help(model.id)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

extension ModelCard {
    
    @ViewBuilder
    func ModelIcon(size: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
        AsyncImage(url: model.organization.flatMap(ModelService.avatarURL(organization:))) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Image(systemName: (model.category ?? .text).systemImage)
                .font(.system(size: size * 0.42))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.tint.opacity(0.12))
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
    
    @ViewBuilder
    func ModelName() -> some View {
        Text(model.displayName)
            .font(.headline)
            .truncationMode(.middle)
            .multilineTextAlignment(.leading)
    }
    
    @ViewBuilder
    func ModelMetadata() -> some View {
        HStack(spacing: 10) {
            if let size = sizeInBytes {
                Label {
                    Text(size, format: .byteCount(style: .file))
                } icon: {
                    Image(systemName: "internaldrive")
                }
                .accessibilityLabel(Text("Size \(size.formatted(.byteCount(style: .file)))"))
            }
            
            Label {
                Text(model.downloads, format: .number.notation(.compactName))
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .accessibilityLabel(Text("\(model.downloads) downloads"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
    
    @ViewBuilder
    func DownloadActionView() -> some View {
        switch downloadState {
        case .notDownloaded:
            Button("Download", systemImage: "arrow.down") {
                createDownloadModelTask()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Download")
            
        case .downloading:
            if let fractionCompleted = downloadTask?.fractionCompleted {
                DownloadProgressButton(
                    fractionCompleted: fractionCompleted,
                    title: "Stop Download",
                    systemImage: "stop.fill",
                    action: stopDownloadTask)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Preparing download")
            }
            
        case .stopped:
            DownloadProgressButton(
                fractionCompleted: downloadTask?.fractionCompleted ?? 0,
                title: "Resume Download",
                systemImage: "play.fill",
                action: resumeDownloadTask)
            
        case .downloaded:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(.green)
                .help("Downloaded")
        }
    }
    
    @ViewBuilder
    func DownloadProgressButton(
        fractionCompleted: Double,
        title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fractionCompleted)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(fractionCompleted, format: .percent.precision(.fractionLength(0))))
        .help(Text(title))
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
        modelContext.persist(ModelTask(modelId: model.id, totalUnitCount: sizeInBytes, type: .download))
    }
    
    func stopDownloadTask() {
        if let runningTask = globalStore.runningTasks[model.id] {
            runningTask.cancel()
            globalStore.runningTasks.removeValue(forKey: model.id)
        }
    }
    
    func resumeDownloadTask() {
        downloadTask?.status = .new
    }
}
