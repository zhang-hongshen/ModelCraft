//
//  UnitConversion.swift
//  ModelCraft
//
//  Created by 张鸿燊 on 24/3/2024.
//

import Foundation

func bytesToGigabytes<T: BinaryFloatingPoint>(_ bytes: T) -> T {
    return bytes / T(1_000_000_000)
}

func bytesToGigabytes<T: BinaryInteger>(_ bytes: T) -> T {
    return bytes / T(1_000_000_000)
}

func bytesToString<T: BinaryInteger>(_ bytes: T) -> String {
    let bytes = Double(bytes)
    let kilobyte = Double(1_000)
    let megabyte = Double(1_000_000)
    let gigabyte = Double(1_000_000_000)
    if bytes < kilobyte {
        return String(format: "%.2f B", bytes)
    } else if bytes < megabyte {
        let kilobytes = Double(bytes) / kilobyte
        return String(format: "%.2f KB", kilobytes)
    } else if bytes < gigabyte {
        let megabytes = Double(bytes) / megabyte
        return String(format: "%.2f MB", megabytes)
    } else {
        let gigabytes = Double(bytes) / gigabyte
        return String(format: "%.2f MB", gigabytes)
    }
}

func bytesToString<T: BinaryFloatingPoint>(_ bytes: T) -> String {
    let bytes = Double(bytes)
    let kilobyte = Double(1_000)
    let megabyte = Double(1_000_000)
    let gigabyte = Double(1_000_000_000)
    if bytes < kilobyte {
        return String(format: "%.2f B", bytes)
    } else if bytes < megabyte {
        let kilobytes = Double(bytes) / kilobyte
        return String(format: "%.2f KB", kilobytes)
    } else if bytes < gigabyte {
        let megabytes = Double(bytes) / megabyte
        return String(format: "%.2f MB", megabytes)
    } else {
        let gigabytes = Double(bytes) / gigabyte
        return String(format: "%.2f MB", gigabytes)
    }
}
