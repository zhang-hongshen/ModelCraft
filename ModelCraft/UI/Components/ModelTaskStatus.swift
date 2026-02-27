//
//  ModelTaskStatus.swift
//  ModelCraft
//
//  Created by Hongshen on 28/3/2024.
//

import SwiftUI

struct ModelTaskStatus: View {
    
    @State var task: ModelTask
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        HStack(alignment: .center) {
            Text("\(ByteCountFormatter.string(fromByteCount: task.completedUnitCount, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: task.totalUnitCount, countStyle: .file))")
                
                Text(task.fractionCompleted, format: .percent.precision(.fractionLength(1)).rounded(rule: .down))
            switch task.status {
            case .new:
                ProgressView().controlSize(.small)
            case .running:
                DeleteTaskButton()
            case .stopped:
                Button {
                    restartTask(task)
                } label: {
                    Image(systemName: "play.fill")
                }.buttonStyle(.borderless)
                DeleteTaskButton()
            case .failed:
                Button("Retry") {
                    restartTask(task)
                }
            default: EmptyView()
            }
        }
    }
    
    @ViewBuilder
    func DeleteTaskButton() -> some View {
        Button {
            deleteTask(task)
        } label: {
            Image(systemName: "xmark.circle.fill")
        }.buttonStyle(.borderless)
    }
    
}

extension ModelTaskStatus {
    func deleteTask(_ task: ModelTask) {
        modelContext.delete(task)
        try? modelContext.save()
    }
    
    func restartTask(_ task: ModelTask) {
        modelContext.delete(task)
        modelContext.insert(ModelTask(modelId: task.modelId, type: .download))
        try? modelContext.save()
    }
}

#Preview {
    let runningTask = ModelTask(modelId: "",
                         status: .running,
                         type: .download)
    let stoppedTask = ModelTask(modelId: "",
                                status: .stopped,
                                type: .download)
    let failedTask = ModelTask(modelId: "",
                                status: .failed,
                                type: .download)
    ModelTaskStatus(task: runningTask)
    ModelTaskStatus(task: stoppedTask)
    ModelTaskStatus(task: failedTask)
}
