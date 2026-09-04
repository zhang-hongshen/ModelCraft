//
//  WebTool.swift
//  ModelCraft
//
//  Created by Hongshen on 5/9/26.
//

import Foundation
import Network

import Alamofire
import MLXLMCommon

@MainActor
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    private(set) var isConnected = false

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let isConnected = path.status == .satisfied
            Task { @MainActor in
                NetworkMonitor.shared.isConnected = isConnected
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.modelcraft.network-monitor"))
    }
}

class WebTool {

    private static let maximumResponseBytes = 2_000_000
    private static let maximumContentLength = 40_000

    static let webFetch = Tool<WebFetchInput, WebFetchOutput>(
        name: ToolNames.webFetch,
        description: "Fetch readable text from one known HTTP or HTTPS URL. Use this when the URL is already available; it does not search the web. Returns the final URL, optional page title, and up to 40,000 characters of text, JSON, or XML content.",
        parameters: [
            .required("url", type: .string, description: "The complete absolute HTTP or HTTPS URL, including its scheme and host.")
        ]
    ) { input in
        guard let url = URL(string: input.url),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw WebFetchError.invalidURL
        }

        let response = await AF.request(
            url,
            headers: [.userAgent("ModelCraft/1.0")],
            requestModifier: { $0.timeoutInterval = 15 }
        )
        .validate(statusCode: 200..<300)
        .serializingData()
        .response

        let data = try response.result.get()
        guard data.count <= maximumResponseBytes else {
            throw WebFetchError.responseTooLarge
        }

        let mimeType = response.response?.mimeType?.lowercased()
        guard mimeType == nil
                || mimeType?.hasPrefix("text/") == true
                || mimeType == "application/json"
                || mimeType == "application/xml"
                || mimeType == "application/xhtml+xml" else {
            throw WebFetchError.unsupportedContentType(mimeType ?? "unknown")
        }

        let isHTML = mimeType == "text/html" || mimeType == "application/xhtml+xml"
        let content = isHTML ? readableText(fromHTML: data) : String(decoding: data, as: UTF8.self)
        let cleanedContent = normalized(content)
        guard !cleanedContent.isEmpty else {
            throw WebFetchError.emptyContent
        }

        return WebFetchOutput(
            url: response.response?.url?.absoluteString ?? url.absoluteString,
            title: isHTML ? title(fromHTML: data) : nil,
            content: String(cleanedContent.prefix(maximumContentLength)))
    }

    private static func readableText(fromHTML data: Data) -> String {
        (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ).string) ?? String(decoding: data, as: UTF8.self)
    }

    private static func title(fromHTML data: Data) -> String? {
        let html = String(decoding: data, as: UTF8.self)
        guard let range = html.range(
            of: #"<title\b[^>]*>(.*?)</title>"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let titleHTML = String(html[range])
            .replacingOccurrences(of: #"<title\b[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</title>"#, with: "", options: [.regularExpression, .caseInsensitive])
        let decoded = readableText(fromHTML: Data(titleHTML.utf8))
        let title = normalized(decoded)
        return title.isEmpty ? nil : title
    }

    private static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

struct WebFetchInput: Codable {
    let url: String
}

struct WebFetchOutput: Codable {
    let url: String
    let title: String?
    let content: String
}

enum WebFetchError: LocalizedError {
    case invalidURL
    case responseTooLarge
    case unsupportedContentType(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The URL must be a complete http or https URL."
        case .responseTooLarge:
            "The web page is larger than 2 MB."
        case .unsupportedContentType(let mimeType):
            "Unsupported web content type: \(mimeType)."
        case .emptyContent:
            "The web page did not contain readable text."
        }
    }
}
