import XCTest
@testable import PenCore

final class BNLToNODTests: XCTestCase {
    /// Synthetic BNL exercises route preservation independently of NOD's writer.
    /// Includes an unreferenced, deliberately undecodable unknown-codec medium.
    private func fixture(secondIDs: [UInt16] = [0], corruptAudio: Bool = false) throws -> BNLBook {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let firmware = root.appendingPathComponent("毛毛虫固件程序版本/毛毛虫二代笔（18版）v103/startup.bin")
        guard FileManager.default.fileExists(atPath: firmware.path) else { throw XCTSkip("Local v103 firmware fixture is unavailable") }
        let context = try BNLContext(firmware: Data(contentsOf: firmware))
        let first = BNLBook.key(context.table1[2]), second = BNLBook.key(context.table2[0])
        var data = Data(repeating: 0xff, count: 0x1400)
        func raw(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
        }
        func pointer(_ offset: Int, _ value: UInt32) throws { raw(offset, try BNLBook.encodePointer(value, first, second)) }
        func word(_ offset: Int, _ value: UInt16) { data[offset] = UInt8(truncatingIfNeeded: value); data[offset+1] = UInt8(value >> 8) }
        data.replaceSubrange(0x1c0..<0x1c9, with: "Chomptech".utf8.map { $0 ^ 0x80 })
        raw(0x160, 0); raw(0x164, 0)
        let tag: UInt32 = (0..<4).reduce(0) { $0 | UInt32(BNLBook.encodeByte(UInt8(truncatingIfNeeded: UInt32(0x47584202) >> ($1*8)), first, second)) << ($1*8) }
        raw(0x1b8, tag)
        try pointer(0, 0x200); try pointer(4, 0x240); try pointer(0x20, 2)
        try pointer(0x194, 1000); try pointer(0x198, 1002); raw(0x19c, 0x218)
        try pointer(0x204, 0x220); try pointer(0x208, 0x230)
        raw(0x20c, 0); raw(0x210, 1); raw(0x214, .max)
        word(0x220, 1); word(0x222, 0)
        word(0x230, UInt16(secondIDs.count))
        for (i, id) in secondIDs.enumerated() { word(0x232+i*2, id) }
        try pointer(0x240, 0x400); try pointer(0x244, 0x01000005)
        try pointer(0x248, 0xe00); try pointer(0x24c, 0x02000003)
        let keys = (0..<16).map { BNLBook.key(context.table1[$0]) }
        var audio = MP3TestFixture.tone
        if corruptAudio {
            audio = Data()
            for _ in 0..<3 { audio.append(contentsOf: [0xff, 0xfb, 0x90, 0]); audio.append(Data(repeating: 0xff, count: 413)) }
            XCTAssertNotNil(MP3Structure.bounds(audio))
        }
        audio.append(Data(repeating: 0, count: 0xa00-audio.count))
        data.replaceSubrange(0x400..<0xe00, with: BNLBook.encodeAudio(audio, offset: 0x400, keys: keys))
        return try BNLBook(data: data, context: context)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testBridgePreservesEachNonemptyOIDAndSkipsUnreferencedUnknownMedia() throws {
        let book = try fixture(), root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("new.nod")
        let original = book.data
        let result = try book.convertToOpenNOD(coverCode: 1000, bookID: 42, to: destination)
        XCTAssertTrue(result.experimental); XCTAssertFalse(result.deviceVerified)
        XCTAssertEqual(result.skippedEmptyRoutes, 1)
        XCTAssertEqual(result.routes.map(\.code), [1000, 1001])
        XCTAssertEqual(result.routes.map(\.isCover), [true, false])
        XCTAssertEqual(result.media.map(\.id), [0])
        XCTAssertEqual(result.media[0].sha256, MP3TestFixture.tone.sha256)
        XCTAssertEqual(result.outputSHA256, try Data(contentsOf: destination).sha256)
        let nod = try NODOpenBook(data: Data(contentsOf: destination))
        XCTAssertEqual(nod.bookID, 42); XCTAssertEqual(nod.userID, "local")
        XCTAssertEqual(nod.coverCodes, [1000]); XCTAssertEqual(nod.coverAudio, MP3TestFixture.tone)
        XCTAssertEqual(nod.routes.map(\.code), [1001]); XCTAssertEqual(nod.routes[0].audio, MP3TestFixture.tone)
        XCTAssertEqual(book.data, original)
        let output = try Data(contentsOf: destination)
        XCTAssertThrowsError(try book.convertToOpenNOD(coverCode: 1000, bookID: 42, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), output)
    }

    func testRejectsMissingOrEmptyCoverAndMultitrackWithoutOutput() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("rejected.nod")
        let book = try fixture()
        for cover in [UInt32(999), 1002] {
            XCTAssertThrowsError(try book.convertToOpenNOD(coverCode: cover, bookID: 1, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        let multi = try fixture(secondIDs: [0, 1])
        XCTAssertThrowsError(try multi.convertToOpenNOD(coverCode: 1000, bookID: 1, to: output))
        XCTAssertThrowsError(try multi.convertToOpenNOD(coverCode: 1001, bookID: 1, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testRejectsReferencedCorruptPayloadAndUnknownCodec() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("rejected.nod")
        let corrupt = try fixture(corruptAudio: true)
        XCTAssertThrowsError(try corrupt.convertToOpenNOD(coverCode: 1000, bookID: 1, to: output))
        let unknown = try fixture(secondIDs: [1])
        XCTAssertThrowsError(try unknown.convertToOpenNOD(coverCode: 1000, bookID: 1, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
