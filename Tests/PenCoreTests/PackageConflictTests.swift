import XCTest
import Darwin
@testable import PenCore

final class PackageConflictTests: XCTestCase {
    typealias P = PackageConflicts
    private func header(_ low: UInt32, _ high: UInt32, key: UInt32 = .max, opaque: UInt8 = 7) -> Data {
        var d = Data(repeating: 0, count: 512)
        func put(_ at: Int, _ value: UInt32, _ n: Int = 4) {
            for i in 0..<n { d[at+i] = UInt8(truncatingIfNeeded: value >> (i*8)) }
        }
        put(0, 11, 2); d[2] = opaque; d[0xee] = opaque
        put(8, key); put(0xd4, 1, 2); put(0xd6, low); put(0xda, high)
        d.replaceSubrange(0xb0..<0xc8, with: Data("SS_Book_Code".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }))
        return d
    }
    private func package(_ low: UInt32, _ high: UInt32, key: UInt32 = .max, opaque: UInt8 = 7) throws -> P.Package {
        try P.Package(name: "test", header: header(low, high, key: key, opaque: opaque),
                      bodyRanges: [.init(start: 1, end: 2), .init(start: low, end: high)])
    }
    func testOpaqueFieldsAreNotIdentityKeys() throws {
        let a = try package(100000, 100010), b = try package(100011, 100020)
        XCTAssertTrue(P.detect([a,b]).isEmpty)
        let c = try package(100005, 100020, opaque: 99)
        let conflicts = P.detect([a,c])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].kind, .highCodeRangeOverlap)
        XCTAssertEqual(conflicts[0].affectedCodes, .init(start: 100005, end: 100010))
        XCTAssertEqual(P.firstMatch(code: 100007, packages: [a,c]), 0)
        XCTAssertEqual(P.firstMatch(code: 100015, packages: [a,c]), 1)
        XCTAssertEqual(P.firstMatch(code: 100007, packages: [c,a]), 0)
    }
    func testFirmwareThresholdsAndIndependentKeys() throws {
        let a = try package(65534, 100000, key: 65534)
        let b = try package(65534, 100000, key: 65534, opaque: 9)
        XCTAssertEqual(P.firstMatch(code: 65534, packages: [a]), 0)
        XCTAssertNil(P.firstMatch(code: 65535, packages: [a]))
        XCTAssertNil(P.firstMatch(code: 99999, packages: [a]))
        XCTAssertEqual(P.firstMatch(code: 100000, packages: [a]), 0)
        let conflicts = P.detect([a,b])
        XCTAssertEqual(conflicts.map(\.kind), [.lowBookCodeDuplicate, .highCodeRangeOverlap])
        XCTAssertEqual(conflicts[1].affectedCodes, .init(start: 100000, end: 100000))
        for invalidKey: UInt32 in [65535, 99999, 100000, .max] {
            let x = try package(10, 11, key: invalidKey)
            XCTAssertTrue(P.detect([x,x]).isEmpty)
            XCTAssertNil(P.firstMatch(code: invalidKey, packages: [x]))
        }
    }
    func testFourOriginalV11Registrations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let names = ["GoGo默认卡-儿歌_364_581.bnf", "JoJo英语单词卡2级_343_556.bnf", "宝宝巴士录音贴纸_214_378.bnf", "宝宝爱画画故事涂鸦册-一起去海边_233_402.bnf"]
        var packages: [P.Package] = []
        for name in names {
            let url = root.appendingPathComponent("samples/tadpole/" + name)
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_flags & 0x40000000 == 0 else { throw XCTSkip("本地 BNF fixture 未下载。") }
            packages.append(try P.Package(name: name, data: Data(contentsOf: url)))
        }
        XCTAssertTrue(packages.allSatisfy { $0.oid3BookCode == .max })
        XCTAssertTrue(P.detect(packages).isEmpty)
        for (i, package) in packages.enumerated() {
            XCTAssertEqual(P.firstMatch(code: package.registrationRanges[0].start, packages: packages), i)
        }
    }
    func testRejectAlteredSystemSelectors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("samples/tadpole/GoGo默认卡-儿歌_364_581.bnf")
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_flags & 0x40000000 == 0 else { throw XCTSkip("本地 BNF fixture 未下载。") }
        let data = try Data(contentsOf: url), book = try BNFBook(data: data), codec = try BNFCodec(fileHeader: data)
        for row in book.commands.prefix(2) {
            for delta in [0, 2, 6, 10] {
                var changed = data
                let page = row.offset / 512 * 512
                var decoded = try codec.decodePage(data.subdata(in: page..<page+512), absoluteOffset: page)
                decoded[row.offset - page + delta] ^= 1
                changed.replaceSubrange(page..<page+512, with: try codec.encodePage(decoded, absoluteOffset: page))
                XCTAssertThrowsError(try P.Package(name: "changed", data: changed))
            }
        }
    }
    func testRejectMalformedRegistrationAndBodyMismatch() throws {
        let body: [P.Interval] = [.init(start: 1, end: 2), .init(start: 100000, end: 100010)]
        XCTAssertThrowsError(try P.Package(name: "x", header: header(100001,100010), bodyRanges: body))
        XCTAssertThrowsError(try P.Package(name: "x", header: header(100010,100000), bodyRanges: body))
        XCTAssertThrowsError(try P.Package(name: "x", header: header(1,100010), bodyRanges: body))
        for count: UInt8 in [0,11,255] {
            var h = header(100000,100010); h[0xd4] = count
            XCTAssertThrowsError(try P.Package(name: "x", header: h, bodyRanges: body))
        }
        var h = header(100000,100010); h[0] = 10
        XCTAssertThrowsError(try P.Package(name: "x", header: h, bodyRanges: body))
        h = header(100000,100010); h[0xb0] = 0
        XCTAssertThrowsError(try P.Package(name: "x", header: h, bodyRanges: body))
        XCTAssertThrowsError(try P.Package(name: "x", header: Data(), bodyRanges: body))
    }
}
