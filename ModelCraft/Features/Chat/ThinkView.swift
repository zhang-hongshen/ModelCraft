//
//  ThinkView.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import SwiftUI

import MarkdownUI

struct ThinkView: View {
    
    @State var think: String
    @State private var isExpanded = false
    @State private var thinkingPhrase: String
    
    private static let thinkingPhrases = [
        "Cerebrating", "Channelling", "Choreographling", "Churning", "Coalescing", "Cogitating",
        "Concocting", "Combobulating", "Conjuring", "Contemplating", "Crunching", "Cultivating",
        "Deciphering", "Discombobulating", "Deliberating", "Divining", "Elucidating", "Embellishing",
        "Enchanting", "Envisioning", "Finagling", "Flibbertigibbeting", "Flowing", "Fiddle-faddling",
        "Forging", "Frolicking", "Germinating", "Hashing",
        "Hatching", "Herding", "Honking", "Hullaballooing", "Hustling",
        "Ideating", "Imagining", "Incubating",
        "Jiving",
        "Levitating",
        "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Moseying", "Mulling", "Mustering", "Musing",
        "Nesting", "Noodling", "Nucleating",
        "Osmosing",
        "Percolating", "Perusing", "Philosophising", "Pollinating", "Pondering", "Pontificating", "Precipitating", "Prestidigitating", "Proofing", "Propagating", "Puttering", "Puzzling",
        "Quantumizing",
        "Razzmatazzing", "Reticulating", "Ruminating",
        "Scheming", "Schlepping", "Scurrying", "Seasoning", "Shimmying", "Shucking", "Simmering", "Slithering", "Smooshing", "Spelunking", "Spinning", "Stewing", "Sussing", "Swirling", "Symbioting", "Synthesizing",
        "Thundering", "Tinkering", "Tomfoolering", "Topsy-turvying", "Transmuting", "Twisting",
        "Unfurling", "Unravelling",
        "Vibing",
        "Wandering", "Whirring", "Wibbling", "Wizarding", "Wrangling", "Whirlpooling"
    ]
    
    init(_ think: String) {
        self.think = think
        self.isExpanded = false
        self._thinkingPhrase = State(initialValue: Self.thinkingPhrases.randomElement() ?? "Thinking")
    }
    
    var body: some View {
        DisclosureGroup(thinkingPhrase, isExpanded: $isExpanded) {
            Markdown(think)
                .markdownTheme(.modelCraft)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
    
        }
    }
}
