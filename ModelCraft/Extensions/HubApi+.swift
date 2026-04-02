//
//  HubApi+.swift
//  ModelCraft
//
//  Created by Hongshen on 23/2/26.
//

import Foundation
@preconcurrency import Hub

extension HubApi {
    
    /// Default HubApi instance configured to download models to the user's Downloads directory
    /// under a 'huggingface' subdirectory.
    static let `default` = HubApi(
        downloadBase: URL.applicationSupportDirectory.appending(path: "huggingface")
    )
}
