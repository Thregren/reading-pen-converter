import XCTest
@testable import PenCore

final class BNLPackageConflictsTests: XCTestCase {
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

    private func package(_ codes: [UInt32], _ context: BNLContext) throws -> Data {
        try BNLWriter.build(header: header(), context: context,
            points: codes.map { .init(code: $0, mediaIDs: [0]) }, audio: [MP3TestFixture.tone])
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    func testOnlyEmptySlotIntersectionStillConflicts() throws {
        let context = try context(), directory = try directory()
        let existing = try package([100, 110], context)
        XCTAssertNil(try BNLBook(data: existing, context: context).routes[5].index)
        try existing.write(to: directory.appendingPathComponent("原包.BNL"))
        XCTAssertThrowsError(try BNLPackageConflicts.validateCandidate(
            data: package([105], context), context: context, directory: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("原包.BNL"))
            XCTAssertTrue(error.localizedDescription.contains("105…105"))
        }
    }
    func testSameTemplateWithAdjacentNonoverlappingBoundsIsAllowed() throws {
        let context = try context(), directory = try directory()
        try package([100, 110], context).write(to: directory.appendingPathComponent("原包.bnl"))
        try BNLPackageConflicts.validateCandidate(data: package([111, 120], context),
                                                context: context, directory: directory)
    }
    func testCorruptAndUnknownPackagesFailClosed() throws {
        let context = try context(), directory = try directory()
        let path = directory.appendingPathComponent("损坏.bnl")
        try Data([0, 1, 2]).write(to: path)
        XCTAssertThrowsError(try BNLPackageConflicts.validateCandidate(
            data: package([100], context), context: context, directory: directory)) { error in
            XCTAssertTrue(error.localizedDescription.contains("损坏.bnl"))
        }
        var unknown = try package([200], context); unknown[0x1a0] = 0
        try unknown.write(to: path)
        XCTAssertThrowsError(try BNLPackageConflicts.validateCandidate(
            data: package([100], context), context: context, directory: directory))
        XCTAssertThrowsError(try BNLPackageConflicts.validateCandidate(
            data: Data(), context: context, directory: directory))
    }
}
