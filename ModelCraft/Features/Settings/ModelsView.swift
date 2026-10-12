//
//  ModelsView.swift
//  ModelCraft
//

import SwiftUI
import Hub

struct ModelsView: View {
    @Environment(UserSettings.self) private var userSettings

    @State private var downloadedModelIDs: Set<String> = []
    @State private var downloadingModelID: String?
    @State private var downloadProgress: Double?
    @State private var deletingModelID: String?
    @State private var modelToDelete: String?
    @State private var errorMessage: String?

    private let imageModelID = "sdxl-turbo"
    private let videoModelIDs = ["minimax-h3", "ltx-video"]

    var body: some View {
        Form {
            Section("Image Generation Model") {
                modelRow(
                    id: imageModelID,
                    title: "Stable Diffusion XL Turbo",
                    selectedID: userSettings.imageGenerationModelID,
                    onSelect: { userSettings.imageGenerationModelID = imageModelID }
                )
            }

            Section("Video Generation Model") {
                modelRow(
                    id: videoModelIDs[0],
                    title: "MiniMax H3",
                    selectedID: userSettings.videoGenerationModelID,
                    onSelect: { userSettings.videoGenerationModelID = videoModelIDs[0] }
                )
                modelRow(
                    id: videoModelIDs[1],
                    title: "LTX Video",
                    selectedID: userSettings.videoGenerationModelID,
                    onSelect: { userSettings.videoGenerationModelID = videoModelIDs[1] }
                )
            }
        }
        .formStyle(.grouped)
        .task { refreshDownloadedModels() }
        .confirmationDialog(
            "Delete this model? Its downloaded files will be removed.",
            isPresented: Binding(
                get: { modelToDelete != nil },
                set: { if !$0 { modelToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Model", role: .destructive) {
                guard let modelToDelete else { return }
                deleteModel(modelToDelete)
            }
            Button("Cancel", role: .cancel) { modelToDelete = nil }
        }
        .alert("Model Operation Failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func modelRow(
        id: String,
        title: LocalizedStringKey,
        selectedID: String,
        onSelect: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            if downloadedModelIDs.contains(id) {
                Button(action: onSelect) {
                    HStack {
                        Image(systemName: selectedID == id ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selectedID == id ? Color.accentColor : Color.secondary)
                        Text(title)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedID == id ? .isSelected : [])

                Spacer()

                if deletingModelID == id {
                    ProgressView().controlSize(.small)
                } else {
                    Button(role: .destructive) {
                        modelToDelete = id
                    } label: {
                        Label("Delete Model", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel("Delete Model")
                    .disabled(downloadingModelID != nil || deletingModelID != nil)
                }
            } else if downloadingModelID == id {
                Text(title)
                if let downloadProgress {
                    ProgressView(value: downloadProgress)
                        .frame(maxWidth: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(downloadProgress.map { "\(Int($0 * 100))%" } ?? "Downloading...")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(title)
                Spacer()
                Button {
                    downloadModel(id)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(downloadingModelID != nil || deletingModelID != nil)
            }
        }
    }

    private func refreshDownloadedModels() {
        var installed = Set<String>()
        if StableDiffusionConfiguration.presetSDXLTurbo.isDownloaded() {
            installed.insert(imageModelID)
        }
        if isH3Downloaded {
            installed.insert(videoModelIDs[0])
        }
        if isLTXVideoDownloaded {
            installed.insert(videoModelIDs[1])
        }
        downloadedModelIDs = installed
    }

    private var isH3Downloaded: Bool {
        let configuration = H3Configuration.presetH3BaseFL2VA
        guard let indexFile = configuration.files[.transformerWeights] else { return false }
        let directory = HubApi.system.localRepoLocation(Hub.Repo(id: configuration.id))
        return FileManager.default.fileExists(atPath: directory.appending(path: indexFile).path)
    }

    private var isLTXVideoDownloaded: Bool {
        let configuration = LTXVideoConfiguration.ltxv2BDistilled
        let directory = HubApi.system.localRepoLocation(Hub.Repo(id: configuration.id))
        return [configuration.files[.transformerWeights], configuration.files[.vaeWeights]]
            .compactMap { $0 }
            .allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    private func downloadModel(_ id: String) {
        downloadingModelID = id
        downloadProgress = nil
        Task {
            do {
                let updateProgress: @Sendable (Progress) -> Void = { progress in
                    Task { @MainActor in
                        guard downloadingModelID == id else { return }
                        downloadProgress = progress.fractionCompleted
                    }
                }
                switch id {
                case "sdxl-turbo":
                    try await StableDiffusionConfiguration.presetSDXLTurbo.download(
                        progressHandler: updateProgress)
                case "minimax-h3":
                    try await H3Configuration.presetH3BaseFL2VA.download(
                        progressHandler: updateProgress)
                case "ltx-video":
                    try await LTXVideoConfiguration.ltxv2BDistilled.download(
                        progressHandler: updateProgress)
                default:
                    return
                }
                downloadedModelIDs.insert(id)
            } catch {
                errorMessage = error.localizedDescription
            }
            downloadingModelID = nil
            downloadProgress = nil
        }
    }

    private func deleteModel(_ id: String) {
        let repositoryID = switch id {
        case "sdxl-turbo": StableDiffusionConfiguration.presetSDXLTurbo.id
        case "minimax-h3": H3Configuration.presetH3BaseFL2VA.id
        case "ltx-video": LTXVideoConfiguration.ltxv2BDistilled.id
        default: ""
        }
        deletingModelID = id
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ModelService.deleteModel(hub: .system, modelID: repositoryID)
                }.value
                downloadedModelIDs.remove(id)
                if userSettings.imageGenerationModelID == id {
                    userSettings.imageGenerationModelID = ""
                }
                if userSettings.videoGenerationModelID == id {
                    userSettings.videoGenerationModelID = videoModelIDs.first {
                        downloadedModelIDs.contains($0)
                    } ?? ""
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            deletingModelID = nil
            modelToDelete = nil
        }
    }
}
