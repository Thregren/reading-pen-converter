import XCTest
@testable import PenCore

final class NODTests: XCTestCase {
    private let parameters = NODOpenParameters(bookID: 12345, userID: "local-research", bookTime: "20261116123000", secret64: Data(0..<64), extInfo: Data("{\"research\":true}".utf8))
    private func output() throws -> Data {
        try NODOpenBook.build(routes: [NODRoute(code: 1002, audio: MP3TestFixture.tone + MP3TestFixture.tone), NODRoute(code: 1001, audio: MP3TestFixture.tone)], coverAudio: MP3TestFixture.tone, coverCodes: [900], parameters: parameters)
    }
    func testVendorCRCTableExceptionAndFixedVectors() {
        // Literal constant from pinned DLL RVA CF220 + 150*4; independently
        // executed against official machine code by nod_machine_oracle.py.
        XCTAssertEqual(NODOpenBook.crc(Data([150])), 0x256c3671)
        XCTAssertNotEqual(NODOpenBook.crc(Data([150])), 0x196c3671)
        XCTAssertEqual(NODOpenBook.crc(Data()), 0)
        XCTAssertEqual(NODOpenBook.verification.count, 64)
    }
    func testCompletePublicNODRoundtripAndDeduplication() throws {
        let data = try output(), book = try NODOpenBook(data: data)
        XCTAssertEqual(book.routes.map(\.code), [1001, 1002])
        XCTAssertEqual(book.routes.map(\.audio), [MP3TestFixture.tone, MP3TestFixture.tone + MP3TestFixture.tone])
        XCTAssertEqual(book.coverAudio, MP3TestFixture.tone); XCTAssertEqual(book.coverCodes, [900])
        XCTAssertEqual(book.bookID, parameters.bookID); XCTAssertEqual(book.userID, parameters.userID)
        XCTAssertEqual(book.bookTime, parameters.bookTime); XCTAssertEqual(book.extInfo, parameters.extInfo)
        let h = NODOpenBook.decodeHeader(Data(data.prefix(0x164)))
        // First route reuses cover bytes; second longer payload remains exact.
        XCTAssertEqual(data.count - Int(try h.u32(0x8c)) - 128, MP3TestFixture.tone.count * 3)
        XCTAssertTrue(NODOpenBook.experimentalHardwareUnverified)
        XCTAssertNotEqual(try output(), data) // Independent random header/index nonces.
        var prefix = Data([9, 9]); prefix.append(MP3TestFixture.tone)
        let sliced = prefix.dropFirst(2)
        let normalized = try NODOpenBook.build(routes: [NODRoute(code: 1, audio: sliced)], coverAudio: sliced, coverCodes: [2], parameters: parameters)
        XCTAssertEqual(try NODOpenBook(data: normalized).routes[0].audio, MP3TestFixture.tone)
    }
    func testTamperingAndSemanticBoundsFailClosed() throws {
        let original = try output()
        for offset in [0x30, 0x170, original.count - 129, original.count - 1] {
            var bad = original; bad[offset] ^= 1
            XCTAssertThrowsError(try NODOpenBook(data: bad))
        }
        let h = NODOpenBook.decodeHeader(Data(original.prefix(0x164)))
        let index = Int(try h.u32(0x68)), key = Data(h[0x100..<0x140])
        var bad = original
        var record = NODOpenBook.decodeIndex(Data(bad[index..<(index + 0x34)]), position: index, key: key)
        NODOpenBook.put(&record, 8, UInt32(bad.count + 1))
        bad.replaceSubrange(index..<(index + 0x34), with: NODOpenBook.encodeIndex(record, position: index, key: key, nonce: Data([1,2,3,4])))
        bad.replaceSubrange((bad.count - 128)..<bad.count, with: NODOpenBook.digest(Data(bad[0x164..<(bad.count - 128)])))
        XCTAssertThrowsError(try NODOpenBook(data: bad)) // Valid CRC/digest; invalid metadata pointer.
        for size in [0, 3, 15, 0x163, 0x1e3] { XCTAssertThrowsError(try NODOpenBook(data: Data(repeating: 0, count: size))) }
    }
    func testInvalidAudioAndParametersRejected() throws {
        let tone = MP3TestFixture.tone
        var frame = Data([0xff, 0xfb, 0x90, 0]); frame.append(Data(repeating: 0xff, count: 413))
        let corrupt = frame + frame + frame
        XCTAssertThrowsError(try NODOpenBook.build(routes: [NODRoute(code: 1, audio: corrupt)], coverAudio: tone, coverCodes: [2], parameters: parameters))
        XCTAssertThrowsError(try NODOpenBook.build(routes: [NODRoute(code: 1, audio: tone)], coverAudio: Data([0,1]), coverCodes: [2], parameters: parameters))
        for codes: [UInt32] in [[], [0], [1], [2,2], Array(2...10)] {
            XCTAssertThrowsError(try NODOpenBook.build(routes: [NODRoute(code: 1, audio: tone)], coverAudio: tone, coverCodes: codes, parameters: parameters))
        }
        XCTAssertThrowsError(try NODOpenBook.build(routes: [NODRoute(code: 1, audio: tone), NODRoute(code: 1, audio: tone)], coverAudio: tone, coverCodes: [2], parameters: parameters))
        for p in [NODOpenParameters(bookID: 1, userID: "", bookTime: "x", secret64: Data(repeating: 0, count: 64)),
                  NODOpenParameters(bookID: 1, userID: "a", bookTime: "", secret64: Data(repeating: 0, count: 64)),
                  NODOpenParameters(bookID: 1, userID: "a", bookTime: "x", secret64: Data(repeating: 0, count: 63)),
                  NODOpenParameters(bookID: 1, userID: "a\0b", bookTime: "x", secret64: Data(repeating: 0, count: 64))] {
            XCTAssertThrowsError(try NODOpenBook.build(routes: [NODRoute(code: 1, audio: tone)], coverAudio: tone, coverCodes: [2], parameters: p))
        }
    }
    func testPythonLayoutInteroperability() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = root.appendingPathComponent("research/nod-local-research.nod")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Optional independent Python research artifact unavailable") }
        let book = try NODOpenBook(data: Data(contentsOf: fixture))
        XCTAssertEqual(book.routes.map(\.code), [1001, 1002]); XCTAssertEqual(book.coverCodes, [900])
        XCTAssertEqual(book.routes[0].audio, MP3TestFixture.tone)
        XCTAssertEqual(book.routes[1].audio, MP3TestFixture.tone + MP3TestFixture.tone)
    }
}
