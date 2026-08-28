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
    
    @Attribute(.unique) var id: String
    var createdAt: Date = Date.now
    var modelID: String
    var totalUnitCount: Int64?
    var completedUnitCount: Int64?
    var fractionCompleted: Double?
    var _type: TaskType.RawValue
    var _status: TaskType.RawValue
    
    @Transient var type: TaskType {
        get { TaskType(rawValue: _type)! }
        set { _type = newValue.rawValue }
    }
    
    @Transient var status: TaskStatus {
        get { TaskStatus(rawValue: _status)! }
        set { _status = newValue.rawValue }
    }
    
    init(modelId: String, totalUnitCount: Int64? = nil,
         completedUnitCount: Int64? = nil, fractionCompleted: Double? = nil,
         status: TaskStatus = .new, type: TaskType) {
        self.id = "\(modelId)-\(type.rawValue)"
        self.modelID = modelId
        self.totalUnitCount = totalUnitCount
        self.completedUnitCount = completedUnitCount
        self.fractionCompleted = fractionCompleted
        self._type = type.rawValue
        self._status = status.rawValue
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
    
    static func fetchByStatus(_ status: TaskStatus) -> FetchDescriptor<ModelTask> {
        let _status = status.rawValue
        let predicate = #Predicate<ModelTask> { $0._status == _status }
        var descriptor = FetchDescriptor<ModelTask>(predicate: predicate)
        descriptor.sortBy = [.init(\.createdAt, order: .reverse)]
        return descriptor
    }
    
    static func fetchByType(_ type: TaskType) -> FetchDescriptor<ModelTask> {
        let _type = type.rawValue
        let predicate = #Predicate<ModelTask> { $0._type == _type}
        var descriptor = FetchDescriptor<ModelTask>(predicate: predicate)
        descriptor.sortBy = [.init(\.createdAt, order: .reverse)]
        return descriptor
    }
    
    static var fetchUnCompletedDownloadTask: FetchDescriptor<ModelTask> {
        let _status = TaskStatus.completed.rawValue
        let _type = TaskType.download.rawValue
        let predicate = #Predicate<ModelTask> {
            $0._type == _type && $0._status != _status }
        var descriptor = FetchDescriptor<ModelTask>(predicate: predicate)
        descriptor.sortBy = [.init(\.createdAt, order: .reverse)]
        return descriptor
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
