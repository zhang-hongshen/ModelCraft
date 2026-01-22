//
//  ThoughtView.swift
//  ModelCraft
//
//  Created by Hongshen on 21/1/26.
//

import SwiftUI


struct ThoughtView: View {
    
    @State var thought: String
    @State private var isExpanded = false
    
    var body: some View {
        DisclosureGroup("Thinking", isExpanded: $isExpanded) {
            Text(thought).foregroundStyle(.secondary)
        }
    }
}
