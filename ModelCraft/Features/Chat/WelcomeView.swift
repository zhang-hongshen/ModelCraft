//
//  WelcomeView.swift
//  ModelCraft
//
//  Created by Hongshen on 2/23/25.
//

import SwiftUI

struct WelcomeView: View {
    
    var body: some View {
        VStack(alignment: .center) {
            Spacer()
            MessageRole.assistant.icon
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 200)
            
            Text("How can I help you today ?").font(.title.bold())
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }
}

#Preview {
    WelcomeView()
}
