//
//  UncompletedDownloadTaskView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 1/28/25.
//

import SwiftUI
import SwiftData

struct UncompletedDownloadTaskView: View {
    
    @Query(filter: ModelTask.predicateUnCompletedDownloadTask(),
           sort: \ModelTask.createdAt,
           order: .reverse)
    private var uncompletedDownloadTasks: [ModelTask] = []
    
    var body: some View {
        ForEach(uncompletedDownloadTasks) { task in
            HStack{
                Label(task.modelName, systemImage: "shippingbox")
                Spacer()
                ModelTaskStatus(task: task)
            }.tag(task.modelName)
        }
    }
}

#Preview {
    UncompletedDownloadTaskView()
}
