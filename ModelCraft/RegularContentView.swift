//
//  RegularContentView.swift
//  ModelCraft
//
//  Created by Hongshen on 15/5/26.
//

import SwiftUI
import SwiftData

struct RegularContentView: View {
    
    @Environment(GlobalStore.self) private var store
    
    var body: some View {
        @Bindable var bindableStore = store
        NavigationSplitView {
            AppNavigationView().navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 210)
        } detail: {
            AppDetailView(tab: store.currentTab)
        }
        .inspector(isPresented: $bindableStore.isFileInspectorPresented) {
            FileInspectorView(
                url: store.previewURL,
                isPresented: $bindableStore.isFileInspectorPresented
            )
        }
    }
    
}


#Preview(traits: .preview) {
    RegularContentView()
}

