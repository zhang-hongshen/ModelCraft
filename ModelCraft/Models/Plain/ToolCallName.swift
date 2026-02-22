//
//  ToolCallName.swift
//  ModelCraft
//
//  Created by Hongshen on 20/2/26.
//


enum ToolCallName: String, Codable {
    case readFromFile = "read_from_file"
    case writeToFile = "write_to_file"
    case executeCommand = "execute_command"
    case composeEmail = "compose_email"
    case composeMessage = "compose_message"
    case openBrowser = "open_browser"
    case searchMap = "search_map"
    case searchRelevantDocuments = "search_relevant_documents"
    case executeAppleScript = "execute_apple_script"
    case captureScreen = "capture_screen"
    case click = "click"
    case move = "move"
}
