//
//  ModelDownloadProgress.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 28/3/2024.
//

import SwiftUI

struct ModelDownloadProgress: View {
    
    @State var task: ModelTask
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        HStack(alignment: .center) {
            if task.value > 0 &&  task.total > 0 {
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(task.value), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: Int64(task.total), countStyle: .file))")
                
                Text(task.progress, format: .percent.precision(.fractionLength(0)).rounded(rule: .down))
            }
            switch task.status {
            case .new:
                ProgressView().controlSize(.small)
            case .running:
                Button {
                    deleteTask(task)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }.buttonStyle(.borderless)
            case .stopped:
                Button {
                    restartTask(task)
                } label: {
                    Image(systemName: "play.fill")
                }.buttonStyle(.borderless)
            case .failed:
                Button("Retry") {
                    restartTask(task)
                }
            default: EmptyView()
            }
        }
    }
    
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
    ModelDownloadProgress(task: ModelTask(modelName: "", type: .download))
}
