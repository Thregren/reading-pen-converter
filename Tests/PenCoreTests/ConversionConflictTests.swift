import XCTest
import Foundation
@testable import PenCore

final class ConversionConflictTests: XCTestCase {
    func testSaveRejectsOverlapAndUnreadableSiblingWithoutCreatingFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf"))
        let audio = try BNFBook(data: data).validatedAudio(at: 0)
        let different = try BNFWriter.write(template: data, points: [.init(code: 100000, mediaIDs: [0])], audio: [audio])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try data.write(to: folder.appendingPathComponent("original.bnf"))
        let duplicate = folder.appendingPathComponent("renamed.bnf")
        XCTAssertThrowsError(try ConversionFiles.save(data, report: ["test": true], to: duplicate))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.appendingPathExtension("conversion.json").path))
        let valid = folder.appendingPathComponent("separate.bnf")
        try ConversionFiles.save(different, report: ["test": true], to: valid)
        XCTAssertEqual(try Data(contentsOf: valid), different)
        XCTAssertThrowsError(try ConversionFiles.save(different, report: ["test": true], to: folder.appendingPathComponent("same-code.bnf")))
        try FileManager.default.removeItem(at: valid)
        try Data([0]).write(to: folder.appendingPathComponent("unknown.bnf"))
        XCTAssertThrowsError(try ConversionFiles.save(different, report: ["test": true], to: folder.appendingPathComponent("unchecked.bnf")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("unchecked.bnf").path))
    }
}
