//
//  ModelStoreModel.swift
//  ModelCraft
//
//  Created by Hongshen on 4/3/26.
//

struct ModelStoreModel: Decodable, ModelEntity {
    let id: String
    let downloads: Int
    let tags: [String]
    let pipelineTag: String?
    
    var isVLM: Bool {
        return pipelineTag == "image-text-to-text" || (pipelineTag?.contains("vision") ?? false)
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case downloads
        case tags
        case pipelineTag
    }
}
