//
//  Bundle+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 26/3/2024.
//

import Foundation

extension Bundle {
    var applicationName: String {
        infoDictionary?[kCFBundleNameKey as String] as? String ?? "ModelCraft"
    }
}
