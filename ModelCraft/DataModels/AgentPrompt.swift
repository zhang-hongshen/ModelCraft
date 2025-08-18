//
//  AgentPrompt.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 12/4/2024.
//

import Foundation
import SwiftUI

class AgentPrompt {
    
    static func answerQuestion(context: String, question: String) -> Message {
        return Message(
            role: .system,
            content: """
            <role>
            You are a powerful AI assistant.
            </role>
            <task>
            Please answer the user's question based on the context provided.
            If the context does not contain the answer, explicitly say so.
            The context is wrapped in the <context> tag.
            User's question is wrapped in the <question> tag.

            Your response MUST be structured with the following tags:
            <answer>...</answer>
            <think>Explain your reasoning process briefly here.</think>
            </task>
            <context>\(context)</context>
            <question>\(question)</question>
            """
        )
    }
    
    static func rollingSummary(previousSummary: String, messages: [Message]) -> Message {
        return Message(
            role: .system,
            content: """
            <role>
            Summarizer
            </role>
            <task>
            Update the rolling summary of the conversation:
            - If no previous summary, create one from the new messages.
            - If a summary exists, merge it with the new messages.
            - Keep it concise: retain goals, facts, decisions, useful context.
            - Skip greetings, filler, or unimportant details.
            </task>
            <previous_summary>
            \(previousSummary)
            </previous_summary>
            <messages>
            \(messages.map { msg in
                switch msg.role {
                case .user:
                    return "User: \(msg.content)"
                case .assistant:
                    return "Assistant: \(msg.content)"
                default:
                    return "\(msg.role.localizedName): \(msg.content)"
                }
            }.joined(separator: "\n"))
            </messages>
            """
        )
    }
    
}
