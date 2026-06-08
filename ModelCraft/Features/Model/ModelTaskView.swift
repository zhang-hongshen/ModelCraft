//
//  ModelTaskView.swift
//  ModelCraft
//
//  Created by Hongshen on 28/3/2024.
//

import SwiftUI

struct ModelTaskView: View {
    
    @State var task: ModelTask
    
    @Environment(\.modelContext) private var modelContext
    @Environment(GlobalStore.self) private var globalStore
    
    var body: some View {
        HStack(alignment: .center) {
            Label(task.modelID, systemImage: "shippingbox")
            Spacer()
            if let fractionCompleted = task.fractionCompleted {
                Text(fractionCompleted, format: .percent.precision(.fractionLength(1)).rounded(rule: .down))
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
            deleteTask()
        } label: {
            Image(systemName: "xmark.circle.fill")
        }.buttonStyle(.borderless)
    }
    
}

extension ModelTaskView {
    
    func deleteTask() {
        modelContext.delete(task)
        try? modelContext.save()
        if let runningTask = globalStore.runningTasks[task.modelID] {
            runningTask.cancel()
            globalStore.runningTasks.removeValue(forKey: task.modelID)
        }
    }
    
    func restartTask(_ task: ModelTask) {
        task.status = .new
    }
}

#Preview(traits: .preview) {
    ScrollView {
        ForEach(ModelTask.previews) {
            ModelTaskView(task: $0)
        }
    }
}
