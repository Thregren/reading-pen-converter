import XCTest
import Foundation
import Darwin
@testable import PenCore

final class BNFBookTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func fixture(_ path: String) throws -> Data {
        let url = root.appendingPathComponent(path)
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_flags & 0x40000000 == 0 else {
            throw XCTSkip("本地 BNF fixture 不存在或尚未下载：\(path)")
        }
        return try Data(contentsOf: url)
    }
    func testFiveOriginalBooksAndLosslessRepack() throws {
        let fixtures: [(String, Int, Int)] = [
            ("research/bnf-program-search-artifacts/mis-61759.bnf", 27, 14),
            ("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf", 27, 1),
            ("samples/tadpole/JoJo英语单词卡2级_343_556.bnf", 206, 351),
            ("samples/tadpole/宝宝巴士录音贴纸_214_378.bnf", 27, 14),
            ("samples/tadpole/宝宝爱画画故事涂鸦册-一起去海边_233_402.bnf", 144, 128)
        ]
        for (path, count, routes) in fixtures {
            let data = try fixture(path), book = try BNFBook(data: data)
            XCTAssertEqual(book.media.count, count)
            if book.commands.contains(where: { $0.isHighFlagged }) {
                XCTAssertThrowsError(try book.audioRoutes(allowSystemControls: true))
                XCTAssertEqual(book.commands.filter { $0.type == 2 }.count, routes)
            } else { XCTAssertEqual(try book.audioRoutes(allowSystemControls: true).count, routes) }
            XCTAssertThrowsError(try book.audioRoutes())
            XCTAssertEqual(try book.repacked(), data)
            let plain = try book.decodedMediaAllocation(at: 0)
            XCTAssertEqual(try book.repacked(mediaAllocations: [0: plain]), data)
            if let row = book.commands.first(where: { $0.type == 2 && $0.reference < UInt32(count) }) {
                let reference = (Int(row.reference) + 1) % count
                let edited = try book.repacked(directReferences: [row.oid!: reference])
                let parsed = try BNFBook(data: edited)
                XCTAssertEqual(parsed.commands[row.index].reference, UInt32(reference))
                XCTAssertEqual(edited.prefix(book.layout.bodyStart), data.prefix(book.layout.bodyStart))
            }
        }
    }
    func testActualPlaylistAndRangeAlignment() throws {
        let gogo = try BNFBook(data: fixture("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf"))
        XCTAssertEqual(gogo.commands[0].oid, 1)
        XCTAssertEqual(gogo.commands[0].type, 30)
        XCTAssertEqual(gogo.commands[1].oid, 2)
        XCTAssertEqual(gogo.commands[2].oid, 91998625)
        XCTAssertEqual(gogo.commands[2].mediaIndices, Array(16...26))
        XCTAssertNil(gogo.commands.last?.oid)
        let v10 = try BNFBook(data: fixture("research/bnf-program-search-artifacts/mis-61759.bnf"))
        XCTAssertEqual(v10.commands[61758].oid, 61759)
        XCTAssertEqual(v10.commands[61758].mediaIndices, [26])
    }
    func testExtractV10WithAPETagsAndV11() throws {
        for path in ["research/bnf-program-search-artifacts/mis-61759.bnf", "samples/tadpole/GoGo默认卡-儿歌_364_581.bnf"] {
            let book = try BNFBook(data: fixture(path))
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("BNF-extract-test-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            let manifest = try book.extract(sourceFilename: URL(fileURLWithPath: path).lastPathComponent, to: destination)
            XCTAssertEqual(manifest.media.count, 27)
            XCTAssertTrue(manifest.media.allSatisfy { ($0.mp3Frames ?? 0) >= 3 })
            XCTAssertEqual(manifest.commands.count, book.commands.count)
            XCTAssertThrowsError(try book.extract(sourceFilename: path, to: destination))
            for item in manifest.media {
                let audio = try Data(contentsOf: destination.appendingPathComponent(item.filename))
                XCTAssertEqual(audio.count, item.audioBytes)
                XCTAssertNoThrow(try MP3Decoder.validate(audio))
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(item.allocationFilename)).count,
                               book.media[item.index].allocationLength)
            }
        }
    }
    func testTruncationFailsWithoutOutput() throws {
        let raw = try fixture("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        XCTAssertThrowsError(try BNFBook(data: raw.prefix(512)))
        XCTAssertThrowsError(try BNFBook(data: raw.dropLast()))
    }
    private func patch(_ data: Data, offset: Int, bytes: [UInt8]) throws -> Data {
        let codec = try BNFCodec(fileHeader: data)
        var result = data
        var pages: [Int: Data] = [:]
        for (index, value) in bytes.enumerated() {
            let q = offset + index, page = q / 512 * 512
            if pages[page] == nil { pages[page] = try codec.decodePage(data.subdata(in: page..<(page + 512)), absoluteOffset: page) }
            pages[page]![q - page] = value
        }
        for (page, plain) in pages { result.replaceSubrange(page..<(page + 512), with: try codec.encodePage(plain, absoluteOffset: page)) }
        return result
    }
    func testControlAndHighFlagCannotSilentlyDisappear() throws {
        let raw = try fixture("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        let book = try BNFBook(data: raw)
        for type: UInt16 in [3, 30, 0x8002] {
            let changed = try patch(raw, offset: book.commands[2].offset, bytes: [UInt8(truncatingIfNeeded: type), UInt8(type >> 8)])
            let parsed = try BNFBook(data: changed)
            XCTAssertThrowsError(try parsed.audioRoutes(allowSystemControls: true))
        }
    }
    func testMalformedDirectoriesAndHeader() throws {
        let raw = try fixture("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        let book = try BNFBook(data: raw), codec = try BNFCodec(fileHeader: raw)
        var wrongSignature = raw; wrongSignature[0xb0] ^= 1
        XCTAssertThrowsError(try BNFBook(data: wrongSignature))
        let duplicateMediaOffset = try patch(raw, offset: book.layout.mediaTableOrigin + 8,
            bytes: Array(try codec.decodePage(raw.subdata(in: book.layout.mediaTableOrigin..<(book.layout.mediaTableOrigin + 512)), absoluteOffset: book.layout.mediaTableOrigin)[4..<8]))
        XCTAssertThrowsError(try BNFBook(data: duplicateMediaOffset))
        let hugeCount = try patch(raw, offset: book.layout.mediaTableOrigin, bytes: [0x99,0x99,0x99,0x99])
        XCTAssertThrowsError(try BNFBook(data: hugeCount))
        let overlapping = BNFBook.Layout(bodyStart: book.layout.bodyStart, commandOrigin: book.layout.mediaTableOrigin,
            mediaTableOrigin: book.layout.mediaTableOrigin, playlistOrigin: book.layout.playlistOrigin, commandCount: book.layout.commandCount)
        XCTAssertThrowsError(try BNFBook(data: raw, codec: codec, layout: overlapping))
        let overflowPlaylist = BNFBook.Layout(bodyStart: book.layout.bodyStart, commandOrigin: book.layout.commandOrigin,
            mediaTableOrigin: book.layout.mediaTableOrigin, playlistOrigin: Int.max, commandCount: book.layout.commandCount)
        XCTAssertThrowsError(try BNFBook(data: raw, codec: codec, layout: overflowPlaylist))
        let rangePointer = try patch(raw, offset: book.layout.bodyStart, bytes: [0xff,0xff])
        XCTAssertThrowsError(try BNFBook(data: rangePointer))
    }
    func testInvalidAudioTagLengthsAndNonFFPadding() throws {
        let book = try BNFBook(data: fixture("research/bnf-program-search-artifacts/mis-61759.bnf"))
        let original = try book.decodedMediaAllocation(at: 0)
        let tag = try XCTUnwrap(original.range(of: Data("APETAGEX".utf8)))
        var changed = original
        changed.replaceSubrange((tag.lowerBound + 12)..<(tag.lowerBound + 16), with: [0xff,0xff,0xff,0xff])
        XCTAssertNil(try BNFBook.strictAudioBounds(changed))
        changed = original; changed[changed.count - 1] = 0
        XCTAssertNil(try BNFBook.strictAudioBounds(changed))
        changed = original; changed.replaceSubrange((tag.lowerBound + 16)..<(tag.lowerBound + 20), with: [0xff,0xff,0xff,0xff])
        XCTAssertNil(try BNFBook.strictAudioBounds(changed))
    }

}
