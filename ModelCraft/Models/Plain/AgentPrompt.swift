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
        
        let toolsJSON = try? JSONEncoder().encode(ToolDefinitions.allTools)
        let tools = String(data: toolsJSON ?? Data(), encoding: .utf8) ?? "No available tools"
        let toolNames = ToolDefinitions.allTools.map{ $0.name }.joined(separator: ",")
        return Message(
            role: .user,
            content: """
            <role>
                Complete the following tasks as best you can.
            </role>
            <available_tools>\(tools)</available_tools>
            <instructions>
                Using the following format:
                <task>the task you must complete</task>
                <thought>you should always think about what to do</thought>
                <action>the action to take, should be one of [\(toolNames)]</action>
                <observation>the result of the action</observation>
                ...(this <thought>/<action>/<observation> can repeat N times)
                <answer>the final answer to the task</answer>
            
                Here is an example.
                <example>
                    <task>Check if 'config.json' exists</task>
                    <thought>I need to list the files in the current directory to check for 'config.json'.</thought>
                    <action>{"tool": "execute_command", "parameters": {"command": "ls"}}</action>
                    <observation>1.txt config.json</observation>
                    <answer>'config.json' exists</answer>
                </example>
            </instructions>
            
            <rules>
            1. No text outside of XML tags.
            2. Thought should focus on decision-making, not storytelling.
            3. If and only if you need to use a tool, output exactly one <action>...</action> .
            4. If no tool is needed, respond with <answer>...</answer>.
            5. You must NEVER output <observation>...</observation>.
            
            </rules>
            
            <context>
                <relevant_documents>
                    \(!relevantDocuments.isEmpty ? relevantDocuments.joined(separator: "\n") : "No relevant documtns")
                <\relevant_documents>
                <history_summary>
                    \(summary ?? "No previous history.")
                </history_summary>
            </context>
            
            Begin!
            
            <task>\(task)</task>
            """
        )
    }
    
    static func summarize<T: RandomAccessCollection>(previousSummary: String?, messages: T) -> Message
        where T.Element == Message{
            
        let conversation = messages.toString()
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
            
            <conversation>
            \(conversation)
            </conversation>
            """
        )
    }
    
    static func generateTitle(messages: [Message]) -> Message {
        let conversation = messages.toString()
        
        return Message(
            role: .user,
            content: """
            <role>
            Generate a short, descriptive title for the conversation below.
            </role>
            
            <instructions>
            1. Length: Under 6 words.
            2. Style: No punctuation, no quotes, no markdown.
            3. Consistency: Use the same language and tone as the conversation.
            4. Output: ONLY the title text itself.
            </instructions>
            
            <conversation>\(conversation)</conversation>
            """)
    }
    
}
