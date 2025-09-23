//
//  Comparable+.swift
//  ModelCraft
//
//  Created by Hongshen on 6/2/2024.
//

extension Comparable {
    func clamp(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}
