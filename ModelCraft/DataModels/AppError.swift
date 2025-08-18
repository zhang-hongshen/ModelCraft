//
//  AppError.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 2/25/25.
//

import Foundation

enum AppError: LocalizedError {
    case noSelectedModel
    case unknown

    var errorDescription: String? {
        switch self {
        case .noSelectedModel:
            return "No selected model."
        case .unknown:
            return "An unknown error occurred."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .noSelectedModel:
            return "Please select one model."
        case .unknown:
            return "Please try again later."
        }
    }
}
