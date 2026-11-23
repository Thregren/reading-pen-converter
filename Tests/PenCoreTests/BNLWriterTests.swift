import XCTest
@testable import PenCore

final class BNLWriterTests: XCTestCase {
    private let originalHeaderHex = "2b4d85962a858596ffffffffebec8597cbf98496cb388596cb788596eb4c8549e73f8596cbb88596cb738596cbf88496ebec8496eb4c8596cb778596cb748596eb4c8596cbf68496cb308596cb708596cbb08596cbf08496cb2f8596cb6f8596cbaf8596cbef8496cb2e8596cb6e8596ffffffffffffffffcb338596ffffffffcb768596cbb68596cb358596cb378596ffffffffcbf58496cb348596ffffffff2a858596ffffffffffffffffffffffffffffffffffffffffea4ca596eb4c8596cbb38596cbf38496cb728596cbf28496cb2d8596cb718596cbb18596cbf18496ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00000000ffffffffffffffffffffffffffffffffffffffffec4d8697cbb48596cbf48496cbf78496600000009f000000cb758596cbb58596cb368596cbb78596ffffffffffffffffffffffffe2888596eba77596ffffffff8b358596709c657e706e657e84050000ffffffff00000000ffffffffffffffffffffffffcbae8596222a6d4affffffffc3e8efedf0f4e5e3e87f7f7f7f7f7f7f323032313037323056322e312e34202032303234303331345665723039ffffff32303234303732343531443435373041"
    private func header() -> Data {
        var bytes = [UInt8](); var index = originalHeaderHex.startIndex
        while index < originalHeaderHex.endIndex {
            let next = originalHeaderHex.index(index, offsetBy: 2)
            bytes.append(UInt8(originalHeaderHex[index..<next], radix: 16)!); index = next
        }
        return Data(bytes)
    }
    private func context() throws -> BNLContext {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("毛毛虫固件程序版本/毛毛虫二代笔（18版）v103/startup.bin")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Original v103 firmware unavailable") }
        return try BNLContext(firmware: Data(contentsOf: url))
    }
    func testOriginalLayoutIncludesRangesEventsAndAllRouteList() throws {
        let context = try context()
        let points = [BNLWritePoint(code: 100, mediaIDs: [0,1]), .init(code: 101, mediaIDs: [1]), .init(code: 104, mediaIDs: [])]
        let out = try BNLWriter.build(header: header(), context: context, points: points, audio: [MP3TestFixture.tone, MP3TestFixture.tone])
        let book = try BNLBook(data: out, context: context)
        func pointer(_ at: Int) throws -> Int {
            let raw = try out.u32(at)
            return Int(raw == 0 || raw == .max ? raw : BNLBook.decodePointer(raw, 68, 4))
        }
        XCTAssertEqual(try pointer(4), try pointer(0xa0))
        XCTAssertEqual(try pointer(0x1c), 3 << 16)
        XCTAssertEqual(try pointer(0x190), 3 * 4)
        XCTAssertEqual(try out.u32(0x150), .max)
        XCTAssertEqual(try out.u32(0x200), .max)
        let end = Int(try out.u32(0x19c))
        XCTAssertEqual(try out.u16(end), 2)
        XCTAssertEqual(try out.u32(end+2), 100)
        XCTAssertEqual(try out.u32(end+6), 104)
        XCTAssertEqual(try out.u32(end+10), 101)
        XCTAssertEqual(try out.u32(end+14), 0) // singleton convention from original packages
        var covered = Set(end..<(end+18))
        for field in BNLWriter.eventFields {
            let at = try pointer(field)
            XCTAssertEqual(try out.u16(at), 0)
            covered.formUnion(at..<(at+2))
        }
        let all = try pointer(0x1b4)
        XCTAssertEqual(try out.u16(all), 3)
        XCTAssertEqual(try (0..<3).map { try out.u16(all+2+$0*2) }, [1,2,3])
        covered.formUnion(all..<(all+8))
        let firstPlaylist = try XCTUnwrap(book.routes.first?.playlistOffset)
        XCTAssertEqual(covered, Set(end..<firstPlaylist))
        XCTAssertNil(book.routes[2].index)
        XCTAssertNil(book.routes[3].index)
        XCTAssertEqual(book.routes[4].mediaIDs, [])
        for track in book.media {
            let audio = try book.allocatedAudio(track)
            XCTAssertEqual(audio.prefix(MP3TestFixture.tone.count), MP3TestFixture.tone)
            XCTAssertGreaterThan(try MP3Decoder.validate(Data(audio.prefix(MP3TestFixture.tone.count))).sampleFrames, 0)
        }
    }
    func testUnsafeTemplateInvalidRoutesAndUnknownMediaAreRejected() throws {
        let context = try context(); let point = BNLWritePoint(code: 100, mediaIDs: [0])
        var changed = header(); changed[0x184] ^= 1
        XCTAssertThrowsError(try BNLWriter.build(header: changed, context: context, points: [point], audio: [MP3TestFixture.tone]))
        XCTAssertThrowsError(try BNLWriter.build(header: header(), context: context, points: [point, point], audio: [MP3TestFixture.tone]))
        XCTAssertThrowsError(try BNLWriter.build(header: header(), context: context, points: [.init(code: 100, mediaIDs: [2])], audio: [MP3TestFixture.tone]))
        XCTAssertThrowsError(try BNLWriter.build(header: header(), context: context, points: [point], audio: [Data([1,2,3])]))
    }
    func testGoGoConversionReportsSystemControlsAndPreservesRoutes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Local GoGo BNF unavailable") }
        let source = try BNFBook(data: Data(contentsOf: url))
        let context = try context()
        // Public API requires a parsed template with the exact audited header.
        let templateURL = root.appendingPathComponent("[需解压使用]牛津阅读树拓展阅读 点读版升级套装 Level 1+ 36册/ORT_L1_The_Journey_P.bnl")
        guard FileManager.default.fileExists(atPath: templateURL.path) else { throw XCTSkip("Local audited template unavailable") }
        let template = try BNLBook(data: Data(contentsOf: templateURL), context: context)
        let recordingURL = root.appendingPathComponent("samples/tadpole/宝宝巴士录音贴纸_214_378.bnf")
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            let recording = try BNFBook(data: Data(contentsOf: recordingURL))
            XCTAssertTrue(recording.commands.contains { $0.isHighFlagged })
            XCTAssertThrowsError(try BNFToBNLConverter.convert(recording, template: template, systemControls: .omitWithReport))
        }
        XCTAssertThrowsError(try BNFToBNLConverter.convert(source, template: template))
        let result = try BNFToBNLConverter.convert(source, template: template, systemControls: .omitWithReport)
        XCTAssertEqual(result.report.omittedSystemControls.map(\.type), [30,3])
        XCTAssertTrue(result.report.omittedSystemControls.allSatisfy { $0.randomWord == .max && $0.trailingWord == 0 })
        let expectedModes = source.commands.filter { $0.oid != nil && $0.type == 2 && $0.trailingWord != 1 }
        XCTAssertEqual(result.report.normalizedPlaybackModes.map(\.oid), expectedModes.map { $0.oid! })
        XCTAssertEqual(result.report.normalizedPlaybackModes.map(\.trailingWord), expectedModes.map(\.trailingWord))
        let reportRoundtrip = try JSONDecoder().decode(BNFToBNLReport.self, from: JSONEncoder().encode(result.report))
        XCTAssertEqual(reportRoundtrip.normalizedPlaybackModes.count, expectedModes.count)
        XCTAssertEqual(result.report.routeCount, 1)
        XCTAssertEqual(result.report.originalMediaIndices, Array(16...26))
        let readback = try BNLBook(data: result.data, context: context)
        XCTAssertEqual(readback.routes.count, 1)
        XCTAssertEqual(readback.routes[0].code, 91998625)
        XCTAssertEqual(readback.routes[0].mediaIDs, Array(0...10))
        for track in readback.media {
            let original = try source.validatedAudio(at: track.id + 16)
            XCTAssertEqual(try readback.allocatedAudio(track).prefix(original.count), original)
        }
    }

}
