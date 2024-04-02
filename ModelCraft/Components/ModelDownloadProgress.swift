//
//  ModelDownloadProgress.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 28/3/2024.
//

import SwiftUI

struct ModelDownloadProgress: View {
    
    @State var task: ModelTask
    
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
                Button(action: /*@START_MENU_TOKEN@*/{}/*@END_MENU_TOKEN@*/, label: {
                    Image(systemName: "stop.fill")
                }).overlay {
                    ProgressView(value: task.value,
                                 total: task.total)
                        .progressViewStyle(.circular)
                        .tint(.accentColor).controlSize(.regular)
                }.buttonStyle(.borderless)
            default: EmptyView()
            }
        }
        .tint(.accentColor)
    }
}

#Preview {
    ModelDownloadProgress(task: ModelTask(type: .download))
}
