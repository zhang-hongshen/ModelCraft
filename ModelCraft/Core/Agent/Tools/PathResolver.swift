//
//  PathResolver.swift
//  ModelCraft
//
//  Created by Hongshen on 31/3/26.
//

import Foundation

struct PathResolver {

    static func resolve(_ path: String) throws -> URL {
        let rootURL = URL.documentsDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = if (path as NSString).isAbsolute {
            URL(fileURLWithPath: path)
        } else {
            rootURL.appendingPathComponent(path)
        }
        let resolvedURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        let resolvedPath = resolvedURL.path

        guard resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") else {
            throw PathResolverError.outsideDocumentsDirectory
        }
        return resolvedURL
    }
}

enum PathResolverError: LocalizedError {
    case outsideDocumentsDirectory

    var errorDescription: String? {
        "The path must be inside the app's Documents directory."
    }
}
