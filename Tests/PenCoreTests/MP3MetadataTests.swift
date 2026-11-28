import Foundation
import XCTest
@testable import PenCore

final class MP3MetadataTests: XCTestCase {
    private func apeTag() -> Data {
        func word(_ value: UInt32) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        let item = word(1) + word(0) + Data("Title\0A".utf8)
        func descriptor(flags: UInt32) -> Data {
            var data = Data("APETAGEX".utf8)
            for field: UInt32 in [2000, UInt32(item.count + 32), 1, flags, 0, 0] {
                data.append(word(field))
            }
            return data
        }
        return descriptor(flags: 0xa0000000) + item + descriptor(flags: 0x80000000)
    }

    func testTagOrdersAndAllocationPadding() throws {
        let mp3 = MP3TestFixture.tone
        let id3 = Data("TAG".utf8) + Data(repeating: 0, count: 125)
        let ape = apeTag()
        for tags in [ape, ape + id3, id3 + ape] {
            let clip = mp3 + tags
            let bnl = clip + Data(repeating: 0, count: 33)
            let bnf = clip + Data(repeating: 255, count: 33)
            let bounds = try XCTUnwrap(MP3Structure.bounds(bnl))
            XCTAssertEqual(bounds.frameEnd, mp3.count)
            XCTAssertEqual(bounds.contentEnd, clip.count)
            XCTAssertEqual(bounds.padding, 33)
            XCTAssertNoThrow(try MP3Decoder.validate(clip))
            XCTAssertEqual(try BNFBook.strictAudioBounds(bnf)?.end, mp3.count)
            XCTAssertNil(MP3Structure.bounds(clip + Data([1])))
            XCTAssertNil(try BNFBook.strictAudioBounds(clip + Data([1])))
        }
    }

    func testDamagedOrTruncatedTagIsRejected() throws {
        var badLength = apeTag()
        badLength[32] = 255
        var badFooter = apeTag()
        badFooter[badFooter.count - 12] = 1
        for tag in [badLength, badFooter, Data(apeTag().dropLast(1))] {
            XCTAssertNil(MP3Structure.bounds(MP3TestFixture.tone + tag))
            XCTAssertNil(try BNFBook.strictAudioBounds(MP3TestFixture.tone + tag))
        }
    }
}
