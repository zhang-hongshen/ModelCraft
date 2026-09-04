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

    static var downloadBaseDirectory: URL {
        UserDefaults.standard.url(forKey: UserDefaults.modelDownloadBaseDirectory)
            ?? UserDefaultSettings.modelDownloadBaseDirectory
    }

    static var modelsDirectory: URL {
        downloadBaseDirectory.appending(path: "models")
    }

    public static var `default`: HubApi {
        HubApi(downloadBase: downloadBaseDirectory)
    }
}
