//
//  Date+.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import Foundation
import SwiftUI

extension Date {
    var localizedDaysAgo : LocalizedStringKey {
        let calendar = Calendar.current
        let now = Date()
        let components = calendar.dateComponents([.day], from: self, to: now)
        
        guard let daysAgo = components.day else {
            return "Today"
        }
        
        switch daysAgo {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        default:
            return "\(daysAgo) days ago"
        }
    }
}
