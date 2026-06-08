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
    
    public static let `default` = HubApi(downloadBase: URL.applicationSupportDirectory)
    
}
