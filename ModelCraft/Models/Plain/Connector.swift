//
//  Connector.swift
//  ModelCraft
//

import AppKit

/// A Mac app that ModelCraft operates through the MCP server the app runs on the loopback interface.
enum Connector: String, CaseIterable, Identifiable {
    case arthub
    case keel
    case tuneStudio = "tunestudio"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .arthub: "Arthub"
        case .keel: "Keel"
        case .tuneStudio: "TuneStudio"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .arthub: "Browse and play the movies, TV shows, and music in your media library."
        case .keel: "Browse and edit the keys in your Redis databases."
        case .tuneStudio: "Put sung vocals on pitch and export the corrected audio."
        }
    }

    var bundleID: String {
        switch self {
        case .arthub: "com.zhanghongshen.Arthub"
        case .keel: "com.zhanghongshen.Keel"
        case .tuneStudio: "com.zhanghongshen.TuneStudio"
        }
    }

    /// Shown in place of the app icon while the app is not on this Mac.
    var systemImage: String {
        switch self {
        case .arthub: "film.stack"
        case .keel: "cylinder.split.1x2"
        case .tuneStudio: "waveform"
        }
    }

    var releasesURL: URL {
        URL(string: "https://github.com/zhang-hongshen/\(name)/releases/latest")!
    }

    /// Sandboxed apps write their Application Support files inside their container.
    private var isSandboxed: Bool {
        switch self {
        case .arthub: false
        case .keel, .tuneStudio: true
        }
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// `{"url": "http://127.0.0.1:<port>/mcp", "token": "<bearer token>"}`, written by the app
    /// to `<its Application Support>/<bundle ID>/mcp.json` each time its server starts listening.
    var endpointFileURL: URL {
        let library = URL.homeDirectory.appending(path: "Library")
        let applicationSupport = isSandboxed
            ? library.appending(path: "Containers/\(bundleID)/Data/Library/Application Support")
            : library.appending(path: "Application Support")
        return applicationSupport.appending(path: "\(bundleID)/mcp.json")
    }

    /// The tool list cached at install time. Its presence is what makes the connector installed.
    var toolsFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "ModelCraft/Connectors/\(rawValue).json")
    }

    /// Model-visible tool names are `<connector>__<server tool name>`.
    var toolNamePrefix: String { "\(rawValue)__" }

    init?(toolName: String) {
        guard let connector = Self.allCases.first(where: { toolName.hasPrefix($0.toolNamePrefix) }) else {
            return nil
        }
        self = connector
    }
}
