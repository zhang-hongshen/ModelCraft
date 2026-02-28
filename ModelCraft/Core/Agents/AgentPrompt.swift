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
        return Message(
            role: .user,
            content: """
            ## Role
            You are a helpful assistant.
            Complete the following tasks as best you can.

            ## Context
            ### Previous Summary
            \(summary ?? "No previous history.")
            
            Task: \(task)
            """
        )
    }
    
    static func summarize<T: RandomAccessCollection>(previousSummary: String?, messages: T) -> Message
        where T.Element == Message{
            
        let conversation = messages.toString()
        return Message(
            role: .user,
            content: """
            ## Role
            You are a Memory Compressor.
            Compress the following conversation history into a concise summary.
            
            ## Context
            ### Previous Summary
            \(previousSummary ?? "None")
            ### Conversation
            \(conversation)
            
            ## Output Format
            ## Background
            (Context of the task)
            
            ## Key Decisions
            (Key technical decisions made)
            
            ## Progress
            (What has been achieved so far)
            
            ## Current State
            (Pending tasks and next steps)
            """
        )
    }
    
    static func generateTitle(messages: [Message]) -> Message {
        let conversation = messages.toString()
        
        return Message(
            role: .user,
            content: """
            ## Role
            You are a title generator.
            Generate a short, descriptive title for the conversation below.
            
            ## Instructions
            1. Length: Under 6 words.
            2. Style: No punctuation, no quotes, no markdown.
            3. Consistency: Use the same language and tone as the conversation.
            4. Output: ONLY the title text itself.
            
            ## Conversation
            \(conversation)
            """)
    }
    
}
