//
//  ModelTaskStatus.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 28/3/2024.
//

import SwiftUI

struct ModelTaskStatus: View {
    
    @State var task: ModelTask
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        HStack(alignment: .center) {
            if task.value > 0 &&  task.total > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(task.value), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(task.total), countStyle: .file))")
                
                Text(task.progress, format: .percent.precision(.fractionLength(1)).rounded(rule: .down))
            }
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
        modelContext.insert(ModelTask(modelName: task.modelName, type: .download))
        try? modelContext.save()
    }
}

#Preview {
    let runningTask = ModelTask(modelName: "",
                         value: 200,
                         total: 1024,
                         status: .running,
                         type: .download)
    let stoppedTask = ModelTask(modelName: "",
                                value: 300*1024,
                                total: 1024*1024,
                                status: .stopped,
                                type: .download)
    let failedTask = ModelTask(modelName: "",
                                value: 400*1024*1024,
                                total: 1024*1024*1024,
                                status: .failed,
                                type: .download)
    ModelTaskStatus(task: runningTask)
    ModelTaskStatus(task: stoppedTask)
    ModelTaskStatus(task: failedTask)
}
