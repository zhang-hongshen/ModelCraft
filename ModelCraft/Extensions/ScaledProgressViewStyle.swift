//
//  ScaledProgressViewStyle.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/26.
//

import SwiftUI

struct ScaledProgressViewStyle: ProgressViewStyle {
    var scale: CGFloat = 0.6
    
    func makeBody(configuration: Configuration) -> some View {
        ProgressView(configuration)
            .scaleEffect(scale)
    }
}

extension ProgressViewStyle where Self == ScaledProgressViewStyle {
    static var scaled: ScaledProgressViewStyle { .init() }
}
