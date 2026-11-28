import Foundation
import XCTest
@testable import PenCore

final class BatchConversionTests: XCTestCase {
    func testMixedBatchKeepsExistingReceiptAndConvertsAfterBadInput() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bnl = root.appendingPathComponent("[需解压使用]牛津阅读树拓展阅读 点读版升级套装 Level 1+ 36册/ORT_L1_The_Journey_P.bnl")
        let bnf = root.appendingPathComponent("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        guard [bnl, bnf].allSatisfy({ fm.fileExists(atPath: $0.path) }) else { throw XCTSkip("Local batch fixtures unavailable") }
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let reserved = try AudioPackageConversion.batchDestination(for: bnl, in: folder).appendingPathExtension("conversion.json")
        try Data([42]).write(to: reserved)
        let missing = folder.appendingPathComponent("missing.bnf")
        var successful = [String]()
        var failed = [URL]()
        for source in [bnl, missing, bnf, bnf] {
            let output = try AudioPackageConversion.batchDestination(for: source, in: folder)
            do {
                _ = try AudioPackageConversion.convert(source, template: source == bnl ? bnf : bnl, to: output)
                XCTAssertTrue(fm.fileExists(atPath: output.appendingPathExtension("conversion.json").path))
                successful.append(output.lastPathComponent)
            } catch {
                failed.append(source)
            }
        }
        XCTAssertEqual(successful, ["ORT_L1_The_Journey_P-音频版 (2).bnf", "GoGo默认卡-儿歌_364_581-音频版.bnl"])
        XCTAssertEqual(failed, [missing, bnf])
        XCTAssertEqual(try Data(contentsOf: reserved), Data([42]))
    }
}
