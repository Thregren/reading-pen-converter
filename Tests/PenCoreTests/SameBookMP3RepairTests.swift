import Foundation
import XCTest
@testable import PenCore

final class SameBookMP3RepairTests: XCTestCase {
    private func donor(_ id: Int, _ audio: Data) throws -> SameBookMP3Repair.Donor {
        _ = try MP3Decoder.validate(audio)
        return .init(id: id, data: audio, bounds: try XCTUnwrap(MP3Structure.bounds(audio)))
    }

    func testID3TaggedTruncationMatchesTheDonorAudio() throws {
        let full = MP3TestFixture.tone
        let tag = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0])
        let allocation = tag + full.dropLast(13) + Data(repeating: 0, count: 170)
        let result = try SameBookMP3Repair.recover(allocation, mediaID: 3, codes: [733101], donors: [donor(4, full)])
        XCTAssertEqual(result.audio, full)
        XCTAssertEqual(result.report.matchedByteStart, 0)
        XCTAssertEqual(result.report.matchedByteEnd, full.count - 13)
        XCTAssertEqual(result.report.donorMediaID, 4)

        // A tag claiming a longer body cannot hide a partial MPEG frame.
        var malformed = allocation
        malformed[9] = 1
        XCTAssertThrowsError(try SameBookMP3Repair.recover(malformed, mediaID: 3, codes: [733101], donors: [donor(4, full)])) {
            XCTAssertTrue($0.localizedDescription.contains("733101"))
        }
    }

    func testIdenticalFragmentWithDifferentFinalFrameReportsAmbiguity() throws {
        let full = MP3TestFixture.tone
        var lastFrame = 0
        for _ in 0..<4 { lastFrame += try XCTUnwrap(MP3Structure.frameLength(full, lastFrame)) }
        let fragment = Data(full.prefix(lastFrame + 4))
        var alternative = full
        // Change a global_gain bit in the last frame's side information
        // after the shared header. Both full tracks remain independently playable.
        alternative[lastFrame + 4 + 5] ^= 0x20
        let one = try donor(8, full)
        let two = try donor(9, alternative)
        let first = try SameBookMP3Repair.recover(fragment, mediaID: 7, codes: [733102], donors: [one])
        let second = try SameBookMP3Repair.recover(fragment, mediaID: 7, codes: [733102], donors: [two])
        XCTAssertNotEqual(first.audio, second.audio)
        XCTAssertThrowsError(try SameBookMP3Repair.recover(fragment, mediaID: 7, codes: [733102], donors: [one, two])) {
            XCTAssertTrue($0.localizedDescription.contains("733102"))
            XCTAssertTrue($0.localizedDescription.contains("多个匹配"))
        }
    }
}
