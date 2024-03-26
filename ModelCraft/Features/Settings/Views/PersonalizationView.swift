//
//  PersonalizationView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 25/3/2024.
//

import SwiftUI

struct PersonalizationView: View {
    
    @AppStorage(UserDefaults.modelShouldKnow)
    private var modelShouldKnow: String = ""
    @AppStorage(UserDefaults.modelShouldRespond)
    private var modelShouldRespond: String = ""
    
    var body: some View {
        VStack(alignment: .leading) {
            Section {
                TextEditor(text: $modelShouldKnow)
            } header: {
                Text("What would you like model to know about you to provide better responses ?")
            }
            Section {
                TextEditor(text: $modelShouldRespond)
            } header: {
                Text("How would you like model to respond ?")
            }
            
        }
    }
}

#Preview {
    PersonalizationView()
}
