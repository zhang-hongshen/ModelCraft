//
//  ModelCraftTests.swift
//  ModelCraftTests
//
//  Created by 张鸿燊 on 22/3/2024.
//

import XCTest
import PDFKit
@testable import ModelCraft

final class ModelCraftTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: "2024-03-16T13:27:29.945803336+08:00") else {
            return
        }
        print("date \(date.formatted())")
    }
    
    // 测试获取环境变量PATH
    func testGetPath() {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        print("path: \(path)")
    }
    
    func testLocale() {
        let supportedLanguages = Bundle.main.localizations
        print("Supported languages: \(supportedLanguages)")
        for languageCode in supportedLanguages {
            let languageName = Locale(identifier: languageCode).localizedString(forLanguageCode: languageCode)
            print("Language code: \(languageCode), Language name: \(languageName ?? "Unknown")")
        }
        let deviceLanguage = Locale.preferredLanguages.first ?? Bundle.main.localizations.first!
        print("Device language code : \(deviceLanguage ?? "Unknown")")
        let languageName = Locale(identifier: deviceLanguage).localizedString(forLanguageCode: deviceLanguage)
        print("Device language: \(languageName ?? "Unknown")")
    }
    
    func testMarkdownToString() throws {
        let thankYouString = try AttributedString(
            markdown:"**Thank you!** Please visit our [website](https://example.com)")
        print("string: \(thankYouString)")
//        print("string: \(thankYouString.)")
        
    }
    
    func testFileCopy() throws {
        let fileManager = FileManager.default
        let documents = try fileManager.url(for: .documentDirectory, in: .userDomainMask,
                        appropriateFor: nil,
                        create: true)
        let source =  documents.appending(path: "test/source/test.pdf")
        print("source: \(source)")
        let destination   =  documents.appending(path: "test/destination/test.pdf")
        print("destination: \(destination)")    
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.copyItem(at: source, to: fileManager.temporaryDirectory.appending(path: source.lastPathComponent))
        print("temporaryDirectory: \(fileManager.temporaryDirectory)")
        print("currentDirectoryPath: \(fileManager.currentDirectoryPath)")
        print("homeDirectoryForCurrentUser: \(fileManager.homeDirectoryForCurrentUser)")
        
    }
    
    func testFileCopyFromOutsideSandboxToSanbox() throws {
        let fileManager = FileManager.default
        let userDocument = URL(filePath: "/Users/zhanghongshen/Documents")
        let userSource =  userDocument.appending(path: "test/source/test.pdf")
        let sanboxDocument = try fileManager.url(for: .documentDirectory, in: .userDomainMask,
                        appropriateFor: nil,
                        create: true)
        var sanboxDestination =  sanboxDocument.appending(path: "test/destination/test.pdf")
        print("source: \(userSource), destination: \(sanboxDestination)")
        try fileManager.copyItem(at: userSource, to: sanboxDestination)
        sanboxDestination = fileManager.temporaryDirectory.appending(path: userSource.lastPathComponent)
        print("source: \(userSource), destination: \(sanboxDestination)")
        try fileManager.copyItem(at: userSource, to: sanboxDestination)
    }
    
    func testOllamaModels() async throws {
        let models = try await OllamaService.shared.models()
        print(models)
    }
    
    func testReadFileToString() throws {
//        let pdf = URL(filePath: "/Users/zhanghongshen/Documents/Interview/20230410.pdf")
//        let text = URL(filePath: "/Users/zhanghongshen/Documents/Interview/test.txt")
//        let xml = URL(filePath: "/Users/zhanghongshen/Documents/Interview/xml.xml")
        let image = URL(filePath: "/Users/zhanghongshen/Pictures/学生证.jpg")
//        print("pdf, \(try pdf.readContent())")
//        print("text, \(try text.readContent())")
//        print("xml, \(try xml.readContent())")
        print("image, \(try image.readContent())")
    }
    
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }

}
