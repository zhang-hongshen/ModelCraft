//
//  SettingsView.swift
//  ModelCraft
//
//  Created by Hongshen on 22/3/24.
//

import SwiftUI

struct SettingsView: View {
    
    enum Tab: String, CaseIterable, Identifiable {
        case general
        case models
        case storage
        case permissions
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
            ModelsView().tag(Tab.models as Tab?)
                .tabItem {
                    Image(systemName: "cube.box")
                    Text("Models")
                }
            StorageView().tag(Tab.storage as Tab?)
                .tabItem {
                    Image(systemName: "externaldrive")
                    Text("Storage")
                }
            PermissionsView().tag(Tab.permissions as Tab?)
                .tabItem {
                    Image(systemName: "hand.raised")
                    Text("Permissions")
                }
        }
    }
}
