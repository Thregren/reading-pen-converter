import XCTest
import Foundation
import Darwin
@testable import PenCore

final class BNFWriterTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture(_ path: String) throws -> Data {
        let url = root.appendingPathComponent(path); var info = stat()
        guard stat(url.path, &info) == 0, info.st_flags & 0x40000000 == 0 else { throw XCTSkip("本地 fixture 未下载：\(path)") }
        return try Data(contentsOf: url)
    }
    func testNewLayoutAndOrderedPlaylists() throws {
        let data = try fixture("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        let template = try BNFBook(data: data)
        let audio = try [0,1,13].map { try template.validatedAudio(at: $0) }
        let points = [BNLWritePoint(code: 93000100, mediaIDs: [0]),
                      BNLWritePoint(code: 93000102, mediaIDs: [1,0,1]),
                      BNLWritePoint(code: 93000103, mediaIDs: [2,2,0])]
        let result = try BNFWriter.write(template: data, points: points, audio: audio)
        let book = try BNFBook(data: result)
        XCTAssertEqual(book.media.count, 3)
        XCTAssertTrue(book.commands.filter { $0.type == 2 }.allSatisfy { $0.trailingWord == 1 })
        XCTAssertEqual(book.ranges.map { [$0.start,$0.end] }, [[1,2],[93000100,93000103]])
        XCTAssertEqual(try book.audioRoutes(allowSystemControls: true).map(\.mediaIndices), [[0],[],[1,0,1],[2,2,0]])
        XCTAssertEqual(try result.u32(0xd6), 93000100); XCTAssertEqual(try result.u32(0xda), 93000103)
        XCTAssertEqual(try result.u32(0xee), try data.u32(0xee)) // Opaque template identity remains explicit.
        for i in 0..<2 {
            let before = template.commands[i], after = book.commands[i]
            XCTAssertEqual(before.type, after.type); XCTAssertEqual(before.reference, after.reference)
            XCTAssertEqual(before.randomWord, after.randomWord); XCTAssertEqual(before.trailingWord, after.trailingWord)
        }
        for i in audio.indices { XCTAssertEqual(try book.validatedAudio(at: i), audio[i]) }
        XCTAssertThrowsError(try BNFWriter.write(template: Data(), points: points, audio: audio))
        XCTAssertThrowsError(try BNFWriter.write(template: data, points: [.init(code: 1, mediaIDs: [0])], audio: audio))
        XCTAssertThrowsError(try BNFWriter.write(template: data, points: [.init(code: 5, mediaIDs: Array(repeating: 0, count: 31))], audio: audio))
    }
    func testTemplateProfileAcceptsFourOriginalsAndRejectsMutations() throws {
        for name in ["GoGo默认卡-儿歌_364_581", "宝宝巴士录音贴纸_214_378", "宝宝爱画画故事涂鸦册-一起去海边_233_402", "JoJo英语单词卡2级_343_556"] {
            let original = try fixture("samples/tadpole/" + name + ".bnf")
            try BNFTemplateProfile.validate(original)
            let track = try BNFBook(data: original).validatedAudio(at: 0)
            let rebuilt = try BNFWriter.write(template: original, points: [.init(code: 100000, mediaIDs: [0])], audio: [track])
            try BNFTemplateProfile.validate(rebuilt)
            XCTAssertEqual(try BNFBook(data: rebuilt).validatedAudio(at: 0), track)
        }
        let data = try fixture("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        let codec = try BNFCodec(fileHeader: data), book = try BNFBook(data: data)
        let pointer = try codec.headerBlock(data.subdata(in: 16..<32), decrypt: true)
        let base = Int(try pointer.u16(0))
        let first = try codec.headerBlock(data.subdata(in: base..<base+512), decrypt: true)
        let second = base + Int(try first.u16(0))
        let header = try codec.headerBlock(data.subdata(in: second..<second+512), decrypt: true)
        for offset in [8,12,0xb0] {
            var changed = data; changed[offset] ^= 1
            XCTAssertThrowsError(try BNFTemplateProfile.validate(changed))
        }
        // Change encrypted parameters without corrupting the cipher itself.
        for offset in [4,0x62,0x15c,0x15e,0x68,0xc,0x14,0x18,0x20,0x64,0x6c] {
            var changed = data, h = header; h[offset] ^= 1
            changed.replaceSubrange(second..<second+512, with: try codec.headerBlock(h, decrypt: false))
            XCTAssertThrowsError(try BNFTemplateProfile.validate(changed), "header \(offset)")
        }
        for absolute in [book.layout.bodyStart, book.layout.bodyStart+2, book.layout.bodyStart+4,
                         book.layout.bodyStart+512+6,
                         book.layout.bodyStart+8, book.layout.commandOrigin+10,
                         book.layout.commandOrigin+12, book.commands.last!.offset+10] {
            let page = absolute / 512 * 512
            var changed = data
            var plain = try codec.decodePage(data.subdata(in: page..<page+512), absoluteOffset: page)
            plain[absolute-page] ^= 1
            changed.replaceSubrange(page..<page+512, with: try codec.encodePage(plain, absoluteOffset: page))
            XCTAssertThrowsError(try BNFTemplateProfile.validate(changed), "body \(absolute)")
            if absolute == book.layout.bodyStart+4 || absolute == book.layout.commandOrigin+10 {
                let altered = try BNFBook(data: changed)
                XCTAssertThrowsError(try altered.audioRoutes(allowSystemControls: true))
            }
        }
        let audio = try book.validatedAudio(at: 0)
        XCTAssertThrowsError(try BNFWriter.write(template: data, points: [.init(code: 99999, mediaIDs: [0])], audio: [audio]))
        let result = try BNFWriter.write(template: data, points: [.init(code: 100000, mediaIDs: [0])], audio: [audio])
        try BNFTemplateProfile.validate(result)
    }
    func testActualBNLToNewBNF() throws {
        let input = try fixture("[需解压使用]牛津阅读树拓展阅读 点读版升级套装 Level 1+ 36册/ORT_L1_Who_Did_That_P.bnl")
        let fw = try fixture("毛毛虫固件程序版本/毛毛虫二代笔（18版）v103/startup.bin")
        let source = try BNLBook(data: input, context: BNLContext(firmware: fw))
        let template = try fixture("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        let result = try BNLToBNFConverter.convert(source, template: template, nonAudio: .omitWithReport)
        let book = try BNFBook(data: result.data), routes = try book.audioRoutes(allowSystemControls: true)
        let tracks = source.media.sorted { $0.id < $1.id }
        let mapping = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id,$0.offset) })
        XCTAssertEqual(routes.map(\.oid), source.routes.map(\.code))
        XCTAssertEqual(routes.map(\.mediaIndices), source.routes.map { $0.mediaIDs.map { mapping[$0]! } })
        XCTAssertEqual(book.media.count, tracks.count)
        for (i,track) in tracks.enumerated() {
            let raw = try source.allocatedAudio(track); let bounds = try XCTUnwrap(MP3Structure.bounds(raw))
            XCTAssertEqual(try book.validatedAudio(at: i), raw.subdata(in: bounds.audioStart..<bounds.frameEnd))
        }
        if !result.report.omittedEventFieldOffsets.isEmpty { XCTAssertThrowsError(try BNLToBNFConverter.convert(source, template: template)) }
    }
}
