//
//  AppTool.swift
//  ModelCraft
//
//  Created by Hongshen on 26/1/26.
//

import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

class AppTool {
    
    private static func open(url: URL) {
        DispatchQueue.main.async {
            #if canImport(AppKit)
            NSWorkspace.shared.open(url)
            #elseif canImport(UIKit)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            #endif
        }
    }
    
    static func composeEmail(recipients: [String], subject: String, body: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipients.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        
        guard let url = components.url else { return }
        open(url: url)
    }

    static func composeMessage(recipients: [String], body: String) {
        var components = URLComponents()
        components.scheme = "sms"
        components.path = recipients.joined(separator: ",")
        components.queryItems = [
            URLQueryItem(name: "body", value: body)
        ]
        
        guard let url = components.url else { return }
        open(url: url)
    }

    static func openBrowser(url: String) {
        guard let url = URL(string: url) else {
            print("Invalid URL")
            return
        }
        
        open(url: url)
    }
    
}
