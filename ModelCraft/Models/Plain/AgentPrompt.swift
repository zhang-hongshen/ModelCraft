//
//  AgentPrompt.swift
//  ModelCraft
//
//  Created by Hongshen on 12/4/2024.
//

import Foundation
import SwiftUI

class AgentPrompt {
    
    static func completeTask(task: String, summary: String? = nil) -> Message{
        
        let toolsJSON = try? JSONEncoder().encode(ToolDefinitions.allTools)
        let tools = String(data: toolsJSON ?? Data(), encoding: .utf8) ?? "No available tools"
        let toolNames = ToolDefinitions.allTools.map{ $0.name.rawValue }.joined(separator: ",")
        return Message(
            role: .user,
            content: """
            <role>
                Complete the following tasks as best you can.
            </role>
            
            <previous_summary>
                \(summary ?? "No previous history.")
            </previous_summary>
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
            You are a Memory Compressor.
            Compress the following conversation history into a concise summary.
            </role>
            
            <previous_summary>\(previousSummary ?? "None")</previous_summary>
            
            <input>\(conversation)</input>
            
            <output_foramt>
            ## Background
            (Context of the task)
            
            ## Key Decisions
            (Key technical decisions made)
            
            ## Progress
            (What has been achieved so far)
            
            ## Current State
            (Pending tasks and next steps)
            </output_format>
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
