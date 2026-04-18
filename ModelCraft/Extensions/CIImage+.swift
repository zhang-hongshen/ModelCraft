//
//  CIImage+.swift
//  ModelCraft
//
//  Created by Hongshen on 8/4/26.
//

import CoreImage
import UniformTypeIdentifiers

extension CIImage {
    
    func cgImage() -> CGImage? {
        let context = CIContext()
        guard let cgImage = context.createCGImage(self, from: self.extent) else {
            return nil
        }
        return cgImage
    }
    
    func data(type: UTType = .png) -> Data? {
        let context = CIContext()
            
        guard let cgImage = cgImage() else {
            return nil
        }
        
        return cgImage.data(type: type)
    }
    
}
