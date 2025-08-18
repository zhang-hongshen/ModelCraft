//
//  TextSplitter.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 11/4/2024.
//

import Foundation

class TextSplitter {
    
    private let separator: CharacterSet
    private let chunkSize: Int
    private let overlap: Int
    
    public static let `default` = TextSplitter()
    
    init(separator: CharacterSet = .newlines, chunkSize: Int = 100, overlap: Int = 20) {
        self.separator = separator
        self.chunkSize = chunkSize
        self.overlap = overlap
    }
    
    func createDocuments(_ text: String) -> [String] {
        return text.components(separatedBy: separator).reduce(into: [String]()) { result, paragraph in
            var startIndex = paragraph.startIndex
            
            while startIndex < paragraph.endIndex {
                let endIndex = paragraph.index(startIndex, offsetBy: chunkSize, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                let chunk = String(paragraph[startIndex..<endIndex])
                result.append(chunk)
                startIndex = endIndex
                
                if endIndex < paragraph.endIndex {
                    let overlapEndIndex = paragraph.index(startIndex, offsetBy: -overlap, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                    startIndex = overlapEndIndex
                }
            }
        }
    }
}
