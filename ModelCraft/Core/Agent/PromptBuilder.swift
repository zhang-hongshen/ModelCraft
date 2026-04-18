//
//  PromptBuilder.swift
//  ModelCraft
//
//  Created by Hongshen on 12/4/2024.
//

import Foundation
import SwiftUI

class PromptBuilder {
    
    static func planner(question: String) -> [Message] {
        return [
            Message(
            role: .system,
            content: """
            <role>
            You are a planning agent.
            </role>

            <task>
            Create a step-by-step plan to solve the user's problem.
            </task>

            <rules>
            1. Only create a plan.
            2. Do NOT execute tools.
            3. Do NOT call any tools.
            4. The plan should contain clear logical steps.
            5. Keep the plan concise.
            </rules>

            <output_format>
            Plan:
            1. ...
            2. ...
            3. ...
            </output_format>
            """
            ),
            Message(
                role: .user,
                content: "<user_question>\(question)</user_question>"
            )]
    }
    
    static let multiStepAgentSystemPrompt = Message(
        role: .system,
        content: """
        <role>
            You are a helpful assistant.
            You can use tools when needed to get information or perform actions.
        </role>
        
        <rules>
        1. Use tools if they help you answer the user’s request.
        2. Do not guess when you can call a tool.
        3. Call at most one tool at a time.
        4. If a tool is not needed, answer directly.
        5. After receiving tool results, continue reasoning and respond naturally.
        6. Return a normal, helpful answer to the user.
        </rules>
        """
    )
    
    static func answerQuestion(question: String, summary: String? = nil) -> Message {
        return Message(
            role: .user,
            content: """
            <context>
                <previous_summary>\(summary ?? "None")</previous_summary>
            </context>
            
            <user_question>\(question)</user_question>
            """
        )
    }
    
    static func summarize<T: RandomAccessCollection>(previousSummary: String?, messages: T) -> [Message]
        where T.Element == Message{
            
        let conversation = messages.toString()
        return [
            Message(
                role: .user,
                content: """
                <role>
                You are a Memory Compressor.
                </role>

                <task>
                Compress the conversation history into a concise structured summary.
                </task>

                <rules>
                1. Keep the summary concise.
                2. Preserve important context and technical details.
                3. Update the previous summary if new information is present.
                4. Remove redundant or irrelevant conversation details.
                5. Focus on information necessary to continue the task.
                </rules>

                <output_format>
                    <background>Context of the task.</background>
                    <key_decisions>Key technical decisions that were made.</key_decisions>
                    <progress>What has been achieved so far.</progress>
                    <current_state>Pending tasks and next steps.</current_state>
                </output_format>
                """
                ),
            Message(
                role: .user,
                content: """
                <context>
                    <previous_summary>\(previousSummary ?? "None")</previous_summary>
                    <conversation>\(conversation)</conversation>
                </context>
                """)]
    }
    
    
    
    static func generateTitle(messages: [Message]) -> [Message] {
        let conversation = messages.toString()
        return [
            Message(
                role: .system,
                content: """
                <role>
                You are a title generator.
                </role>

                <task>
                Generate a short descriptive title for the conversation.
                </task>

                <rules>
                1. The title must be under 6 words.
                2. Do not use punctuation.
                3. Do not use quotes.
                4. Do not use markdown.
                5. Use the same language as the conversation.
                6. Output only the title text.
                </rules>
                """),
            Message(
                role: .user,
                content: "<conversation>\(conversation)</conversation>"
            )]
    }
}
