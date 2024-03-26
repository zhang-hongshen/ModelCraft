//
//  ModelTask.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import Foundation
import SwiftData

enum TaskStatus: Int {
    case new
    case running
    case completed
    case failed
}

enum TaskType: Int {
    case download
    case delete
}

@Model
class ModelTask {
    @Attribute(.unique) let id = UUID()
    let createdAt: Date = Date.now
    var modelName: String
    var value: Double
    var total: Double
    var typeID: Int
    @Transient var type: TaskType {
        get { TaskType(rawValue: typeID) ?? .download }
        set { self.typeID = newValue.rawValue }
    }
    var statusID: Int
    @Transient var status: TaskStatus {
        get { TaskStatus(rawValue: typeID) ?? .new }
        set { self.statusID = newValue.rawValue }
    }
    
    init(modelName: String = "", value: Double = 0, total: Double = 0,
         status: TaskStatus = .new, type: TaskType) {
        self.modelName = modelName
        self.value = value
        self.total = total
        self.typeID = type.rawValue
        self.statusID = status.rawValue
    }
}

extension ModelTask {
    
    // Predicate by Status
    static func predicateByStatus(_ status: TaskStatus) -> Predicate<ModelTask> {
        let statusID = status.rawValue
        return #Predicate<ModelTask> { $0.statusID == statusID }
    }

}
