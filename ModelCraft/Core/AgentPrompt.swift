//
//  AgentPrompt.swift
//  ModelCraft
//
//  Created by Hongshen on 12/4/2024.
//

import Foundation
import SwiftUI

class AgentPrompt {
    
    static func completeTask(context: String, task: String) -> Message {
        return Message(
            role: .system,
            content: """
            <role>
            You are a powerful AI assistant.
            You must think step by step, decide on actions, observe results,
            and continue until you can provide a final answer.
            </role>
            
            <instructions>
            Follow this workflow strictly:

            1. Read the user's question.
            2. Use <think> to reason about what to do next.
            3. Use <action> to perform an action or finish the task.
            4. Use <observation> to record the result of the action.
            5. Repeat the cycle as needed.
            5. When you are ready to answer the user, output <answer>.
               The appearance of <answer> means the process is complete.
            </instructions>
            
            <available_tools>
            <Search>Search for external information</Search>
            <Calculator>Perform calculations</Calculator>
            </available_tools>
            
            <rules>
            1. Use only one action at a time.
            2. Do not skip steps.
            3. Thought should focus on decision-making, not storytelling.
            4. Do not include any extra text outside the XML tags.
            </rules>
            
            <context>\(context)</context>
            <task>\(task)</task>
            """
        )
    }
    
    static func rollingSummary(previousSummary: String, messages: [Message]) -> Message {
        return Message(
            role: .system,
            content: """
            <role>
            You are an assistant that maintains a concise rolling summary of a conversation.
            </role>
            <instructions>
            1. If <previous_summary> is empty, create a new summary based solely on <messages>.
            2. If <previous_summary> exists, merge it with the new information from <messages>:
               - Preserve essential context, goals, facts, decisions, or constraints from the previous summary.
               - Add or update key points from the new messages that change the situation, reveal new facts, or refine goals.
               - Remove outdated or irrelevant information.
            3. Keep the summary objective and concise — 3 to 6 sentences maximum.
            4. Exclude greetings, small talk, and unimportant details.
            5. Do not include instructions, explanations, or formatting other than plain text.

            Your response must contain only the updated summary text — no XML tags or metadata.
            </instructions>

            <previous_summary>
            \(previousSummary)
            </previous_summary>

            <messages>
            \(messages.map { msg in
                switch msg.role {
                case .user:
                    return "<user>\(msg.content)</user>"
                case .assistant:
                    return "<assistant>\(msg.content)</assistant>"
                default:
                    return "<other>\(msg.content)</other>"
                }
            }.joined(separator: "\n"))
            </messages>
            """
        )
    }
    
    static func generateTitle(messages: [Message]) -> Message {
        return Message(
            role: .user,
            content: """
            <task>
            Generate a short, descriptive title for the conversation below.
            </task>
            
            <instructions>
            1. Keep it under 6 English words or 10 Chinese characters.
            2. Match the language of the conversation.
            3. Use Title Case for English titles.
            4. No punctuation or quotation marks.
            </instructions>
            
            <messages>
            \(messages.map { msg in
                switch msg.role {
                case .user:
                    return "<user>\(msg.content)</user>"
                case .assistant:
                    return "<assistant>\(msg.content)</assistant>"
                default:
                    return "<other>\(msg.content)</other>"
                }
            }.joined(separator: "\n"))
            </messages>
            """)
    }
    
}
