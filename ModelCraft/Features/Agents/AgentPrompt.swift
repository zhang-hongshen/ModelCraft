//
//  AgentPrompt.swift
//  ModelCraft
//
//  Created by Hongshen on 12/4/2024.
//

import Foundation
import SwiftUI

class AgentPrompt {
    
    static func completeTask(task: String, relevantDocuments: [String], summary: String? = nil) -> Message{
        
        let toolsJSON = try? JSONSerialization.data(withJSONObject: ToolDefinitions.allTools)
        let tools = String(data: toolsJSON ?? Data(), encoding: .utf8) ?? "No available tools"
        return Message(
            role: .user,
            content: """
            <role>
            You are a powerful AI assistant.
            You must think step by step, decide on actions, observe results,
            and continue until you can provide a final answer.
            </role>

            <instructions>
            Follow this workflow strictly:
            1. Think: Reason about the current state and what is needed.
            2. Action: Call a tool using: <action>{"tool": "toolName", "parameters": {...}}</action>
            3. Observation: The system will provide the result. (Do not hallucinate this)
            4. Answer: Once the task is finished, use: <answer>final result</answer>
            </instructions>
            
            <available_tools>\(tools)</available_tools>
            
            <rules>
            1. Only one <action> per response.
            2. No text outside of XML tags.
            3. Thought should focus on decision-making, not storytelling.
            </rules>
            
            <example>
                <task>Check if 'config.json' exists</task>
                <think> I need to list the files in the current directory to check for 'config.json'. </think>
                <action> {"tool": "execute_command", "parameters": {"command": "ls"}} </action>
                <observation>1.txt config.json</observation>
                <answer>'config.json' exists</answer>
            </example>
            
            
            <context>
                <relevant_documents>
                    \(!relevantDocuments.isEmpty ? relevantDocuments.joined(separator: "\n") : "No relevant documtns")
                <\relevant_documents>
                <history_summary>
                    \(summary ?? "No previous history.")
                </history_summary>
            </context>
            
            <task>\(task)</task>
            """
        )
    }
    
    static func summarize<T: RandomAccessCollection>(previousSummary: String?, messages: T) -> Message
        where T.Element == Message{
        let messageString = messages.map { msg in
            switch msg.role {
            case .user:
                return "<user>\(msg.content)</user>"
            case .assistant:
                return "<assistant>\(msg.content)</assistant>"
            default:
                return "<other>\(msg.content)</other>"
            }
        }.joined(separator: "\n")
        
        return Message(
            role: .user,
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
            \(previousSummary ?? "None")
            </previous_summary>
            
            <messages>
            \(messageString)
            </messages>
            """
        )
    }
    
    static func generateTitle(messages: [Message]) -> Message {
        let messageString = messages.map { msg in
            switch msg.role {
            case .user:
                return "<user>\(msg.content)</user>"
            case .assistant:
                return "<assistant>\(msg.content)</assistant>"
            default:
                return "<other>\(msg.content)</other>"
            }
        }.joined(separator: "\n")
        
        return Message(
            role: .user,
            content: """
            <role>
            Generate a short, descriptive title for the conversation below.
            </role>
            
            <instructions>
            1. Keep it under 6 English words or 10 Chinese characters.
            2. Match the language of the conversation.
            3. Use Title Case for English titles.
            4. No punctuation or quotation marks.
            </instructions>
            
            <messages>
            \(messageString)
            </messages>
            """)
    }
    
}
