//
//  ModelStoreModel.swift
//  ModelCraft
//
//  Created by Hongshen on 4/3/26.
//

struct ModelStoreModel: Decodable, Identifiable {
    let id: String
    let modelID: String
    let downloads: Int
    let tags: [String]
    let pipelineTag: String?
    
    var isVLM: Bool {
        return pipelineTag == "image-text-to-text" || (pipelineTag?.contains("vision") ?? false)
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case modelID = "modelId"
        case downloads
        case tags
        case pipelineTag
    }
}

extension ModelStoreModel {
    
    var displayName: String {
        id.components(separatedBy: "/").last ?? id
    }
}
