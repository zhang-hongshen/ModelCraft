//
//  CompactContentView.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI

struct CompactContentView: View {
    
    @Environment(GlobalStore.self) private var globalStore
    
    @State private var path: [AppNavigationTab?] = [nil]
    
    var body: some View {
        NavigationStack(path: $path) {
            AppNavigationView()
                .navigationDestination(for: AppNavigationTab.self) { newTab in
                    AppDetailView(tab: newTab)
                }
                .onChange(of: globalStore.currentTab) { oldValue, newValue in
                    path.append(newValue)
                }
        }
    }
}

#Preview(traits: .preview) {
    CompactContentView()
}
