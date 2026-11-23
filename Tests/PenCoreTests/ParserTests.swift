import XCTest
@testable import PenCore
final class ParserTests: XCTestCase {
    func testFirmwareDerivedByteVectorsAndConditionalXor() {
        XCTAssertEqual(BNLBook.decodeByte(0x22, 0x44, 0x04), 0x02)
        XCTAssertEqual(BNLBook.decodeByte(0x2a, 0x44, 0x04), 0x42)
        XCTAssertEqual(BNLBook.decodeByte(0x6d, 0x44, 0x04), 0x58)
        XCTAssertEqual(BNLBook.decodeByte(0x4a, 0x44, 0x04), 0x47)
        for key in UInt16(0)...255 {
            let key = UInt8(key)
            let values = (UInt16(0)...255).map { BNLBook.xor(UInt8($0), key) }
            XCTAssertEqual(Set(values).count, 256)
            XCTAssertEqual(BNLBook.xor(0, key), 0)
            XCTAssertEqual(BNLBook.xor(255, key), 255)
            XCTAssertTrue((UInt16(0)...255).allSatisfy { BNLBook.xor(values[Int($0)], key) == UInt8($0) })
        }
    }
    func testMP3AllocationPaddingAndTags() throws {
        var data = Data()
        for _ in 0..<3 { data.append(contentsOf: [0xff, 0xfb, 0x90, 0]); data.append(Data(repeating: 0, count: 413)) }
        let frameEnd = data.count
        data.append(contentsOf: [0x54, 0x41, 0x47]); data.append(Data(repeating: 0x41, count: 125))
        data.append(Data(repeating: 0, count: 17))
        let bounds = try XCTUnwrap(MP3Structure.bounds(data))
        XCTAssertEqual(bounds.frames, 3)
        XCTAssertEqual(bounds.frameEnd, frameEnd)
        XCTAssertEqual(bounds.contentEnd, frameEnd + 128)
        XCTAssertEqual(bounds.padding, 17)
        data[data.count - 1] = 1
        XCTAssertNil(MP3Structure.bounds(data))
        XCTAssertNil(MP3Structure.bounds(Data([0x49,0x44,0x33,4,0,0,0x7f,0x7f,0x7f,0x7f])))
        XCTAssertNil(MP3Structure.bounds(Data(repeating: 0, count: 512)))
    }
    func testUnrecognizedFirmwareCannotSupplyBNLKeys() {
        XCTAssertThrowsError(try BNLContext(firmware: Data(repeating: 0, count: 0x60000)))
    }
    func testTruncatedFieldsAreRejected() throws {
        let bytes = Data([1, 2, 3])
        XCTAssertEqual(try bytes.u16(0), 513)
        XCTAssertThrowsError(try bytes.u16(-1))
        XCTAssertThrowsError(try bytes.u32(0))
        XCTAssertThrowsError(try bytes.u32(Int.max))
        XCTAssertThrowsError(try FirmwareAudio.clips(in: bytes))
    }
    func testFirmwareExtractionBoundsAndIdentity() throws {
        var data = Data(repeating: 0, count: 0x200)
        let marker = Data("OID-READER".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
        data.replaceSubrange(0..<marker.count, with: marker)
        func write32(_ position: Int, _ value: UInt32) {
            for i in 0..<4 { data[position + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        write32(0xa0, 0x400080)
        write32(0x100, 8); write32(0x104, 12)
        data.replaceSubrange(0x108..<0x10c, with: [0xff, 0xfb, 0x90, 0x00])
        let clips = try FirmwareAudio.clips(in: data)
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].offset, 0x108)
        XCTAssertEqual(clips[0].length, 4)
        write32(0x104, 0x10000)
        XCTAssertThrowsError(try FirmwareAudio.clips(in: data))
    }
    func testBNLIndexRequiresMatchingCountAndBounds() throws {
        var data = Data(repeating: 0xff, count: 0x224)
        data.replaceSubrange(0x1c0..<0x1c9, with: "Chomptech".utf8.map { $0 ^ 0x80 })
        data.replaceSubrange(0x19c..<0x1a0, with: [0x24, 0x02, 0, 0])
        for value in 0..<4 {
            let offset = 0x214 + value * 4
            data.replaceSubrange(offset..<(offset + 4), with: [UInt8(value), 0, 0, 0])
        }
        XCTAssertEqual(BNLEvidence.index(in: data)?.values, 4)
        data[0x19e] = 0xff
        XCTAssertNil(BNLEvidence.index(in: data))
    }
    func testBNFRejectsTruncatedAndReversedRanges() throws {
        var data = Data(repeating: 0, count: 0x100)
        let marker = "SS_Book_Code".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }
        data.replaceSubrange(0xb0..<0xc8, with: marker)
        data[0] = 11; data[0xd4] = 1
        data[0xd6] = 7; data[0xda] = 9
        XCTAssertEqual(try BNFMetadata.read(data).ranges.first?.count, 3)
        data[0xda] = 6
        XCTAssertThrowsError(try BNFMetadata.read(data))
        data[0xd4] = 0xff
        XCTAssertThrowsError(try BNFMetadata.read(data))
        XCTAssertThrowsError(try BNFMetadata.read(Data(repeating: 0, count: 0xff)))
    }
    func testExistingReportIsNeverOverwritten() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("original".utf8).write(to: file)
        let report = try Inspector.inspect(file)
        XCTAssertThrowsError(try Inspector.saveReport(report, to: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
    }
}
