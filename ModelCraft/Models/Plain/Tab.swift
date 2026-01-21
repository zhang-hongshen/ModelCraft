//
//  Tab.swift
//  ModelCraft
//
//  Created by Hongshen on 19/1/26.
//

enum Tab: Hashable {
    case chat(Chat)
    case knowledgeBase(KnowledgeBase)
    case modelStore, downloadedModels
}
