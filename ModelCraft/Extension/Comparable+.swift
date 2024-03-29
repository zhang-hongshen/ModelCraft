//
//  Comparable+.swift
//  Arthub
//
//  Created by 张鸿燊 on 6/2/2024.
//

extension Comparable {
    func clamp(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}
