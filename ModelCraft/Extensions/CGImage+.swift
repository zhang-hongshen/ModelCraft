//
//  CGImage+.swift
//  ModelCraft
//
//  Created by Hongshen on 7/4/26.
//

import CoreImage
import UniformTypeIdentifiers

extension CGImage {
    
    func data(type: UTType = .png) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else { return nil }
        
        CGImageDestinationAddImage(destination, self, nil)
        
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        
        return data as Data
    }
    
    func save(to url: URL) {
        let type = UTType(filenameExtension: url.pathExtension) ?? UTType.png
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, self, nil)
        if !CGImageDestinationFinalize(destination) {
        }
    }
    
}
