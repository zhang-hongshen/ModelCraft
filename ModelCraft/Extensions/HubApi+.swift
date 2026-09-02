//
//  HubApi+.swift
//  ModelCraft
//
//  Created by Hongshen on 17/5/26.
//

import Foundation

import Hub
import HuggingFace


extension HubApi {

    static let defaultDownloadBase = URL.applicationSupportDirectory
        .appending(path: "huggingface")

    static let defaultModelsDirectory = defaultDownloadBase
        .appending(path: "models")

    public static let `default` = HubApi(
        downloadBase: defaultDownloadBase
    )
}
