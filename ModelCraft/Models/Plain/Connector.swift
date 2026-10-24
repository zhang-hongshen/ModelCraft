//
//  Connector.swift
//  ModelCraft
//

import AppKit

/// A Mac app that ModelCraft operates through the MCP server the app runs on the loopback interface.
enum Connector: String, CaseIterable, Identifiable {
    case arthub
    case cellar
    case keel
    case tuneStudio = "tunestudio"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .arthub: "Arthub"
        case .cellar: "Cellar"
        case .keel: "Keel"
        case .tuneStudio: "TuneStudio"
        }
    }

    var summary: LocalizedStringResource {
        switch self {
        case .arthub: "Browse and play the movies, TV shows, and music in your media library."
        case .cellar: "Search the pages, databases, and notes in your knowledge base."
        case .keel: "Browse and edit the keys in your Redis databases."
        case .tuneStudio: "Put sung vocals on pitch and export the corrected audio."
        }
    }

    /// Prefixes each of the connector's tool descriptions, so the model can tell from the
    /// schema alone which requests the app's data answers without the user naming the app.
    var modelDescription: String {
        switch self {
        case .arthub:
            "Arthub is the user's media library on this Mac: the movies, TV shows, music, and videos they own. Use it when the user asks about their movies, shows, songs, or what is playing, even without naming Arthub."
        case .cellar:
            "Cellar is the user's notes and personal knowledge base: the pages, documents, and databases they wrote. Use it when the user asks about something they noted, saved, or wrote down, or what they know about a topic, even without naming Cellar."
        case .keel:
            "Keel is the user's Redis client: the keys and values in the Redis databases they connected. Use it when the user asks about their Redis data, even without naming Keel."
        case .tuneStudio:
            "TuneStudio is the user's vocal tuning app: it puts sung vocals on pitch and exports the corrected audio. Use it when the user wants a vocal recording tuned, even without naming TuneStudio."
        }
    }

    var bundleID: String {
        switch self {
        case .arthub: "com.zhanghongshen.Arthub"
        case .cellar: "com.zhanghongshen.Cellar"
        case .keel: "com.zhanghongshen.Keel"
        case .tuneStudio: "com.zhanghongshen.TuneStudio"
        }
    }

    /// Rendered from the app's AppIcon.icon by `scripts/render-connector-icons.sh`.
    var iconName: String { "Connectors/\(name)" }

    var releasesURL: URL {
        URL(string: "https://github.com/zhang-hongshen/\(name)/releases/latest")!
    }

    /// Sandboxed apps write their Application Support files inside their container.
    private var isSandboxed: Bool {
        switch self {
        case .arthub: false
        case .cellar, .keel, .tuneStudio: true
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
