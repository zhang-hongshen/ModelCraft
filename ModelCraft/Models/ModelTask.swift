//
//  ModelTask.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import Foundation
import SwiftData
import SwiftUI

enum TaskType: Int, Codable {
    case download
    case delete
}

enum TaskStatus: Int, Codable {
    case new
    case running
    case stopped
    case completed
    case failed
}

@Model
class ModelTask {
    
    @Attribute(.unique) var id = UUID()
    var createdAt: Date = Date.now
    var modelName: String
    var value: Double
    var total: Double
    var typeID: Int
    var statusID: Int
    var type: TaskType {
        get { TaskType(rawValue: typeID)! }
        set { typeID = newValue.rawValue }
    }
    var status: TaskStatus {
        get { TaskStatus(rawValue: statusID)! }
        set { statusID = newValue.rawValue }
    }
    
    init(modelName: String, value: Double = 0, total: Double = 0,
         status: TaskStatus = .new, type: TaskType) {
        self.modelName = modelName
        self.value = value
        self.total = total
        self.typeID = type.rawValue
        self.statusID = status.rawValue
    }
}

extension ModelTask {
    
    @Transient var progress: Double {
        if total == 0 { return 0 }
        return (value / total).clamp(to: 0...1)
    }
    
    @Transient var statusLocalizedDescription: LocalizedStringKey {
        switch status {
        case .new:
            switch type {
                case .download: "Waiting to download"
                case .delete: "Waiting to delete"
            }
        case .running:
            switch type {
                case .download: "Downloading..."
                case .delete: "Deleting..."
            }
        case .stopped: "Stopped"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

extension ModelTask {
    
    // Predicate by Status
    static func predicateByStatus(_ status: TaskStatus) -> Predicate<ModelTask> {
        let statusID = status.rawValue
        return #Predicate<ModelTask> { $0.statusID == statusID }
    }
    
    // Predicate by Type
    static func predicateByType(_ type: TaskType) -> Predicate<ModelTask> {
        let typeID = type.rawValue
        return #Predicate<ModelTask> { $0.typeID == typeID }
    }
    
    static func predicateUnCompletedDownloadTask() -> Predicate<ModelTask> {
        let typeID = TaskType.download.rawValue
        let statusID = TaskStatus.completed.rawValue
        return #Predicate<ModelTask> { $0.typeID == typeID && $0.statusID != statusID }
    }
}
