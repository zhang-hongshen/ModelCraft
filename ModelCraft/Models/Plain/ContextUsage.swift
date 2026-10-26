//
//  ContextUsage.swift
//  ModelCraft
//
//  Created by Hongshen on 25/10/26.
//

import Foundation

/// The fixed parts of a chat's prompt, counted from each part's text alone. The rest of the
/// prompt is the conversation's messages.
struct ContextUsage: Equatable {
    var systemPrompt = 0
    var tools = 0
}

extension ContextUsage {

    /// Measures the system prompt and tool schemas the chat's next request would send.
    @MainActor
    static func measure(chat: Chat, model: LocalModel) async throws -> ContextUsage {
        let toolSchemas = ToolDefinition.allToolSchema(for: chat).compactMap { tool -> String? in
            guard JSONSerialization.isValidJSONObject(tool),
                  let data = try? JSONSerialization.data(withJSONObject: tool, options: [.sortedKeys])
            else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }
        let counts = try await LMService.shared.tokenCounts(
            model: model,
            texts: [
                PromptBuilder.system(project: chat.project, summary: chat.summary).content,
                toolSchemas.joined(separator: "\n")
            ])
        return ContextUsage(systemPrompt: counts[0], tools: counts[1])
    }
}
