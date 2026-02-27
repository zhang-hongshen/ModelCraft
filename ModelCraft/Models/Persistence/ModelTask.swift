//
//  ModelTask.swift
//  ModelCraft
//
//  Created by Hongshen on 24/3/2024.
//

import Foundation
import SwiftData
import SwiftUI


@Model
class ModelTask {
    
    @Attribute(.unique) var id = UUID()
    var createdAt: Date = Date.now
    var modelId: String
    var totalUnitCount: Int64
    var completedUnitCount: Int64
    var fractionCompleted: Double
    @Transient var type: TaskType {
        get { TaskType(rawValue: _type)! }
        set { _type = newValue.rawValue }
    }
    var _type: TaskType.RawValue
    @Transient var status: TaskStatus {
        get { TaskStatus(rawValue: _status)! }
        set { _status = newValue.rawValue }
    }
    var _status: TaskType.RawValue
    
    init(modelId: String, totalUnitCount: Int64 = 0,
         completedUnitCount: Int64 = 0, fractionCompleted: Double = 0,
         status: TaskStatus = .new, type: TaskType) {
        self.modelId = modelId
        self.totalUnitCount = totalUnitCount
        self.completedUnitCount = completedUnitCount
        self.fractionCompleted = fractionCompleted
        self._type = type.rawValue
        self._status = type.rawValue
    }
}

extension ModelTask {
    
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
        let _status = status.rawValue
        return #Predicate<ModelTask> { $0._status == _status }
    }
    
    // Predicate by Type
    static func predicateByType(_ type: TaskType) -> Predicate<ModelTask> {
        let _type = type.rawValue
        return #Predicate<ModelTask> { $0._type == _type}
    }
    
    static var predicateUnCompletedDownloadTask: Predicate<ModelTask> {
        let _status = TaskStatus.completed.rawValue
        let _type = TaskType.download.rawValue
        return #Predicate<ModelTask> {
            $0._type == _type && $0._status == _status }
    }
    
    static var predicateUnCompletedTask: Predicate<ModelTask> {
        let _status = TaskStatus.completed.rawValue
        return #Predicate<ModelTask> { $0._status != _status }
    }
}

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
