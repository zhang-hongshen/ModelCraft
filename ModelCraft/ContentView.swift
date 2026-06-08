//
//  ContentView.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/2024.
//

import SwiftUI
import SwiftData
import OrderedCollections

struct ContentView: View {
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        if horizontalSizeClass == .regular {
            RegularContentView()
        } else {
            CompactContentView()
        }
        
    }
}

#Preview(traits: .preview) {
    ContentView()
}
