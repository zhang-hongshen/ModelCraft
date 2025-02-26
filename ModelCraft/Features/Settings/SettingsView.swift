//
//  SettingsView.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 22/3/2024.
//

import SwiftUI

struct SettingsView: View {
    
    enum Tab: String, CaseIterable, Identifiable {
        case general
        var id: Self { self }
    }
    
    @State private var currentTab: Tab? = Tab.general
    
    var body: some View {
        
        TabView(selection: $currentTab) {
            GeneralView().tag(Tab.general as Tab?)
                .tabItem {
                    Image(systemName: "gearshape")
                    Text("General")
                }
        }
        .tabViewStyle(.automatic)
    }
}
