//
//  PullModelResponse.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 23/3/2024.
//

import Foundation

/// A structure that represents the response to a pull model request from the Ollama API.
public struct PullModelResponse: Decodable {
    public var status: String
    public var digest: String?
    public var total: Int?
    public var completed: Int?
}
