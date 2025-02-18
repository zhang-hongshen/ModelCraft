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
    
    func testEchoPath() async throws {
        if let paths = ProcessInfo.processInfo.environment["PATH"] {
            for path in paths.split(separator: ":") {
                print("xcode path = \(path)")
            }
        }
        let paths = "/opt/homebrew/anaconda3/bin:/opt/homebrew/anaconda3/condabin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/Library/Apple/usr/bin:/Users/zhanghongshen/Library/Application Support/JetBrains/Toolbox/scripts"
            .split(separator: ":")
        for path in paths {
            print("path = \(path)")
        }
        print(Bundle.main.bundlePath)
    }
    
    func testReadFileToString() async throws {
       let bundle = Bundle(for: type(of: self))        
        guard let url = bundle.url(forResource: "jfk", withExtension: "mp3") else {
           XCTFail("File not found")
           return
       }
        print("123", url.path())
        print("audio content: ", try await url.readContent())
    }
    
    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        measure {
            // Put the code you want to measure the time of here.
        }
    }
    
    

}
