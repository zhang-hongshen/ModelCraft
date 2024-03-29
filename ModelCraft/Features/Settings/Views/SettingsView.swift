//
//  SettingsView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI

struct SettingsView: View {
    
    enum Tab: String, CaseIterable, Identifiable {
        case general, model, personalization
        var id: Self { self }
    }
    
    @State private var currentTab: Tab? = Tab.general
    
    var body: some View {
        
        TabView(selection: $currentTab) {
            Group {
                GeneralView().tag(Tab.general as Tab?)
                    .tabItem {
                        Image(systemName: "gearshape")
                        Text("General")
                    }
                
                ModelsView().tag(Tab.model as Tab?)
                    .tabItem {
                        Image(systemName: "shippingbox")
                        Text("Models")
                    }
                PersonalizationView().tag(Tab.personalization as Tab?)
                    .tabItem {
                        Image(systemName: "person.bubble")
                        Text("Personalization")
                    }
            }.padding()
        }
        .tabViewStyle(.automatic)
    }
}
