//
//  PromptSuggestion.swift
//  ModelCraft
//
//  Created by Hongshen on 25/3/2024.
//

import Foundation

struct PromptSuggestion: Identifiable {
    let id = UUID()
    var title: String
    var description: String
    var prompt: String
    
    init(title: String, description: String, prompt: String) {
        self.title = title
        self.description = description
        self.prompt = prompt
    }
    
    static func examples() -> [PromptSuggestion] {
        return [
            PromptSuggestion(title: "Help me pick", description: "a birthday gift for my mom who likes gardening", prompt: "Help me pick a birthday gift for my mom who likes gardening. But don't give me gardening tools – she already has all of them!"),
            PromptSuggestion(title: "Plan an itinerary", description: "for a fashion-focused exploration of Paris", prompt: "What can I do in Paris for 5 days, if I'm especially interested in fashion?"),
            PromptSuggestion(title: "Write a spreadsheet formula", description: "to convert a date to the weekday", prompt: "Can you write me a spreadsheet formula to convert a date in one column to the weekday (like \"Thursday\")?"),
            PromptSuggestion(title: "Show me a code snippet", description: "of a website's sticky header", prompt: "Show me a code snippet of a website's sticky header in CSS and JavaScript."),
            PromptSuggestion(title: "Make a content strategy", description: "for a newsletter featuring free local weekend events", prompt: "Make a content strategy for a newsletter featuring free local weekend events."),
            PromptSuggestion(title: "Tell me a fun fact", description: "about the Golden State Warriors", prompt: "Tell me a random fun fact about the Golden State Warriors"),
            PromptSuggestion(title: "Suggest fun activities", description: "to do indoors with my high-energy dog", prompt: "What are five fun and creative activities to do indoors with my dog who has a lot of energy?"),
            PromptSuggestion(title: "Suggest fun activities", description: "for a family of 4 to do indoors on a rainy day", prompt: "Can you suggest fun activities for a family of 4 to do indoors on a rainy day?"),
            PromptSuggestion(title: "Create a charter", description: "to start a film club", prompt: "Create a charter to start a film club that hosts weekly screenings and discussions"),
            PromptSuggestion(title: "Plan a trip", description: "to see the best of New York in 3 days", prompt: "I'll be in New York for 3 days. Can you recommend what I should do to see the best of the city?"),
            PromptSuggestion(title: "Tell me a fun fact", description: "about the Roman Empire", prompt: "Tell me a random fun fact about the Roman Empire")
        ]
    }
}
