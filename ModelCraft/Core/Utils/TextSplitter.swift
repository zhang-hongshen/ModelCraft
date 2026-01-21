//
//  TextSplitter.swift
//  ModelCraft
//
//  Created by Hongshen on 23/9/25.
//

public protocol TextSplitter {
    
    /// Split the given text into chunks/documents.
    /// - Parameter text: Input text.
    /// - Returns: An array of chunk strings.
    func createDocuments(_ text: String) -> [String]
}
