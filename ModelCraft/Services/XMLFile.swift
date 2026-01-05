//
//  XMLFile.swift
//  ModelCraft
//
//  Created by Hongshen on 2/4/2024.
//

import Foundation

class XMLFile: XMLParser {
    
    private var content = ""
    
    func readContent(url: URL) -> String {
        if let parser = XMLParser(contentsOf: url) {
            parser.delegate = self
            parser.parse()
        }
        print("parse xml ended")
        return content
    }
}

extension XMLFile: XMLParserDelegate {
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI titlespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        content.append(string)
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI titlespaceURI: String?, qualifiedName qName: String?) {
    }
}
