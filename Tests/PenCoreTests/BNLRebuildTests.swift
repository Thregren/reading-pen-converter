import XCTest
@testable import PenCore

final class BNLRebuildTests: XCTestCase {
    func testConditionalPointerArithmeticAndInverse() throws {
        let vectors: [(UInt32, UInt32)] = [(0x96854d2b, 0x200), (0x96854ceb, 0),
            (0, 0x0b0b0b0b), (.max, 0x13131313), (0x12345678, 0x2cbc5f6e),
            (0xedcba988, 0x77d9dad7), (0xedcba987, 0x77d9e2d7), (0x3523eb8a, 0x48d0f8d8)]
        for (raw, plain) in vectors {
            XCTAssertEqual(BNLBook.decodePointer(raw, 0x44, 4), plain)
            if raw == 0 || raw == .max {
                // Fields reserve these raw words as absent sentinels, even though
                // the firmware arithmetic wrapper itself maps them elsewhere.
                XCTAssertThrowsError(try BNLBook.encodePointer(plain, 0x44, 4))
            } else {
                let rebuilt = try BNLBook.encodePointer(plain, 0x44, 4)
                XCTAssertNotEqual(rebuilt, 0); XCTAssertNotEqual(rebuilt, .max)
                XCTAssertEqual(BNLBook.decodePointer(rebuilt, 0x44, 4), plain)
            }
        }
        // The key order is observable for exception values, not just combined XOR.
        for key in [UInt8(4), 0xd4] {
            for value in UInt16(0)...255 {
                let x = UInt8(value)
                XCTAssertEqual(BNLBook.encodeByte(BNLBook.decodeByte(x, 0x44, key), 0x44, key), x)
            }
        }
    }

    private func fixture() throws -> (BNLBook, BNLContext) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let firmware = root.appendingPathComponent("毛毛虫固件程序版本/毛毛虫二代笔（18版）v103/startup.bin")
        guard FileManager.default.fileExists(atPath: firmware.path) else { throw XCTSkip("Local v103 firmware fixture is unavailable") }
        let context = try BNLContext(firmware: Data(contentsOf: firmware))
        let first = BNLBook.key(context.table1[2]), second = BNLBook.key(context.table2[0])
        var data = Data(repeating: 0xff, count: 5120)
        func raw(_ at: Int, _ value: UInt32) {
            for index in 0..<4 { data[at + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        func pointer(_ at: Int, _ value: UInt32) throws { raw(at, try BNLBook.encodePointer(value, first, second)) }
        data.replaceSubrange(0x1c0..<0x1c9, with: "Chomptech".utf8.map { $0 ^ 0x80 })
        raw(0x160, 0); raw(0x164, 0)
        let tag: UInt32 = (0..<4).reduce(0) { $0 | UInt32(BNLBook.encodeByte(UInt8(truncatingIfNeeded: UInt32(0x47584202) >> ($1 * 8)), first, second)) << ($1 * 8) }
        raw(0x1b8, tag)
        try pointer(0, 0x200); try pointer(4, 0x220); try pointer(0x20, 2)
        try pointer(0x194, 1000); try pointer(0x198, 1000); raw(0x19c, 0x20c)
        try pointer(0x204, 0x210); raw(0x208, 0)
        data[0x210] = 1; data[0x211] = 0; data[0x212] = 0; data[0x213] = 0
        try pointer(0x220, 0x400); try pointer(0x224, 0x01000005)
        try pointer(0x228, 0xe00); try pointer(0x22c, 0x01000003)
        let keys = (0..<16).map { BNLBook.key(context.table1[$0]) }
        var mp3 = MP3TestFixture.tone
        mp3.append(Data(repeating: 0, count: 2560 - mp3.count))
        data.replaceSubrange(0x400..<0xe00, with: BNLBook.encodeAudio(mp3, offset: 0x400, keys: keys))
        let unknown = Data((0..<1536).map { UInt8(truncatingIfNeeded: $0 * 17) })
        data.replaceSubrange(0xe00..<0x1400, with: BNLBook.encodeAudio(unknown, offset: 0xe00, keys: keys))
        return (try BNLBook(data: data, context: context), context)
    }

    func testRebuildPreservesUnknownMediaAndRelocatesAudio() throws {
        let (book, context) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoded = root.appendingPathComponent("decoded"), exact = root.appendingPathComponent("exact.bnl")
        let manifest = try book.extract(sourceFilename: "fixture.bnl", to: decoded)
        XCTAssertEqual(manifest.media[1].filename, "0001.bin")
        let report = try book.rebuild(decodedDirectory: decoded, to: exact)
        XCTAssertEqual(report.outputSHA256, book.sourceSHA256)
        XCTAssertEqual(try Data(contentsOf: exact), book.data)
        XCTAssertThrowsError(try book.rebuild(decodedDirectory: decoded, to: exact))
        let clip = decoded.appendingPathComponent("0000.mp3")
        var longer = try Data(contentsOf: clip); longer.append(longer)
        let pcm = try MP3Decoder.validate(longer)
        XCTAssertGreaterThan(pcm.sampleFrames, 0)
        try longer.write(to: clip)
        let modified = root.appendingPathComponent("modified.bnl")
        let changed = try book.rebuild(decodedDirectory: decoded, to: modified)
        XCTAssertEqual(changed.changedMediaIDs, [0])
        let result = try BNLBook(data: Data(contentsOf: modified), context: context)
        XCTAssertEqual(result.routes, book.routes)
        XCTAssertEqual(result.media[1].offset - book.media[1].offset, 2048)
        XCTAssertEqual(try result.allocatedAudio(result.media[1]), try book.allocatedAudio(book.media[1]))
        let audio = try result.allocatedAudio(result.media[0])
        XCTAssertEqual(audio.prefix(longer.count), longer)
        // Unknown bytes can be preserved but must never become an unchecked replacement.
        try Data([1, 2, 3]).write(to: decoded.appendingPathComponent("0001.bin"))
        let rejected = root.appendingPathComponent("bad.bnl")
        XCTAssertThrowsError(try book.rebuild(decodedDirectory: decoded, to: rejected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }

    func testFrameHeadersCannotSubstituteForDecodableMP3Payload() throws {
        var corrupt = Data()
        for _ in 0..<3 {
            corrupt.append(contentsOf: [0xff, 0xfb, 0x90, 0])
            corrupt.append(Data(repeating: 0xff, count: 413))
        }
        XCTAssertNotNil(MP3Structure.bounds(corrupt))
        XCTAssertThrowsError(try MP3Decoder.validate(corrupt))
        let (book, _) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoded = root.appendingPathComponent("decoded"), output = root.appendingPathComponent("bad.bnl")
        _ = try book.extract(sourceFilename: "fixture.bnl", to: decoded)
        try corrupt.write(to: decoded.appendingPathComponent("0000.mp3"))
        XCTAssertThrowsError(try book.rebuild(decodedDirectory: decoded, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testMediaTableCannotOverlapAudio() throws {
        let (book, context) = try fixture()
        var broken = book.data
        let raw = try BNLBook.encodePointer(0x228, book.pointerKeys.0, book.pointerKeys.1)
        for index in 0..<4 { broken[0x220 + index] = UInt8(truncatingIfNeeded: raw >> (index * 8)) }
        XCTAssertThrowsError(try BNLBook(data: broken, context: context))
    }

    func testManifestAndOutsideLinksAreRejectedBeforeWriting() throws {
        let (book, _) = try fixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoded = root.appendingPathComponent("decoded"), output = root.appendingPathComponent("output.bnl")
        _ = try book.extract(sourceFilename: "fixture.bnl", to: decoded)
        let clip = decoded.appendingPathComponent("0000.mp3"), outside = root.appendingPathComponent("outside.mp3")
        try FileManager.default.moveItem(at: clip, to: outside)
        try FileManager.default.createSymbolicLink(at: clip, withDestinationURL: outside)
        XCTAssertThrowsError(try book.rebuild(decodedDirectory: decoded, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let manifest = decoded.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        object["sourceSHA256"] = "wrong-template"
        try JSONSerialization.data(withJSONObject: object).write(to: manifest)
        XCTAssertThrowsError(try book.rebuild(decodedDirectory: decoded, to: output))
    }
}
