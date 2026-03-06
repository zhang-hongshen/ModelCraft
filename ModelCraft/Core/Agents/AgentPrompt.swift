//
//  AgentPrompt.swift
//  ModelCraft
//
//  Created by Hongshen on 12/4/2024.
//

import Foundation
import SwiftUI

class AgentPrompt {
    
    static func planner(question: String) -> Message {
        return Message(
            role: .user,
            content: """
            ## Role
            You are a planning agent.

            Create a step-by-step plan to solve the user's problem.

            # Rules
            - Only create a plan.
            - Do NOT execute tools.
            - The plan should contain clear logical steps.
            - Keep the plan concise.

            ## Output Format
            Plan:
            1. ...
            2. ...
            3. ...

            ## User's Question
            \(question)
            """
        )
    }
    
    static func answerQuestion(question: String, plan: String, summary: String? = nil) -> Message {
        return Message(
            role: .user,
            content: """
            ## Role
            You are a helpful assistant that executes a plan step by step.

            ## Context
            
            ### Plan
            \(plan)
            
            ### Previous Summary
            \(summary ?? "No previous history.")
            
            ## Rules
            - Follow the plan step by step.
            - If information is required, call the appropriate tool.
            - Use tool calls instead of guessing information.
            - Only call one tool at a time.
            - After receiving tool results, continue solving the task.
            
            When the task is completed, return the final answer to the user.
            
            ## User's Question 
            \(question)
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
