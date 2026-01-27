//
//  AppTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation
import AppKit

class AppTool {
    
    static func composeEmail(recipients: [String], subject: String, body: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipients.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        
        guard let url = components.url else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    static func composeMessage(recipients: [String], body: String) {
        var components = URLComponents()
        components.scheme = "sms"
        components.path = recipients.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "body", value: body)
        ]
        
        guard let url = components.url else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    static func openBrowser(url: String) {
        guard let urlPath = URL(string: url) else {
            print("Invalid URL")
            return
        }
        
        DispatchQueue.main.async {
            NSWorkspace.shared.open(urlPath)
        }
    }

}
