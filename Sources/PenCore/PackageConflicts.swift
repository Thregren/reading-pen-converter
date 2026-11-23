import Foundation

/// Static model of the audited P19171 firmware lookup path. Not A8S hardware validation.
public enum PackageConflicts {
    public static let evidenceScope = "P19171 固件静态查找模型；尚未在 A8S 实机验证。"
    public struct Interval: Codable, Equatable, Sendable {
        public let start: UInt32
        public let end: UInt32
        public init(start: UInt32, end: UInt32) { self.start = start; self.end = end }
    }
    public struct Package: Codable, Sendable {
        public let name: String
        public let oid3BookCode: UInt32
        public let registrationRanges: [Interval]
        public init(name: String, data: Data) throws {
            let book = try BNFBook(data: data)
            if book.ranges.contains(where: { $0.start <= 2 }) {
                // Exclusion is valid only for the fully audited group/bank selector profile.
                try BNFTemplateProfile.validate(data)
                for (oid, type) in [(UInt32(1), UInt16(30)), (UInt32(2), UInt16(3))] {
                    let rows = book.commands.filter { $0.oid == oid }
                    guard rows.count == 1, let row = rows.first, row.type == type,
                          row.reference == .max, row.randomWord == .max, row.trailingWord == 0 else {
                        throw PenError.invalid("BNF OID 1/2 不符合已验证的组/bank 选择器；无法应用此冲突模型。")
                    }
                }
            }
            try self.init(name: name, header: data, bodyRanges: book.ranges.map { Interval(start: $0.start, end: $0.end) })
        }
        // Separately testable parsing boundary; callers use the full-book initializer above.
        init(name: String, header: Data, bodyRanges: [Interval]) throws {
            let header = Data(header)
            guard header.count >= 512, try header.u16(0) == 11,
                  header.subdata(in: 0xb0..<0xc8) == Data("SS_Book_Code".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }) else {
                throw PenError.invalid("冲突检测只支持具有 SS_Book_Code 注册头的 BNF v11。")
            }
            let count = Int(try header.u16(0xd4))
            // Firmware list record reserves 0x50 bytes for interval pairs.
            guard count > 0, count <= 10 else { throw PenError.invalid("BNF 注册码段数量超出固件索引容量。") }
            var ranges: [Interval] = []
            for i in 0..<count {
                let low = try header.u32(0xd6 + i * 8), high = try header.u32(0xda + i * 8)
                guard low <= high, low > 2, !ranges.contains(where: { low <= $0.end && high >= $0.start }) else {
                    throw PenError.invalid("BNF 注册码段倒置、重叠或包含系统控制码。")
                }
                ranges.append(Interval(start: low, end: high))
            }
            // OID 1/2 are local system commands, not external book-registration ranges.
            let content = bodyRanges.compactMap { r -> Interval? in
                guard r.end > 2 else { return nil }
                return Interval(start: max(3, r.start), end: r.end)
            }
            func normalized(_ items: [Interval]) -> [Interval] {
                var result: [Interval] = []
                for item in items.sorted(by: { $0.start < $1.start }) {
                    if let last = result.last, UInt64(item.start) <= UInt64(last.end) + 1 {
                        result[result.count - 1] = Interval(start: last.start, end: max(last.end, item.end))
                    } else { result.append(item) }
                }
                return result
            }
            guard normalized(content) == normalized(ranges) else {
                throw PenError.invalid("BNF 明文注册码段与正文书籍码段不一致。")
            }
            self.name = name; oid3BookCode = try header.u32(8); registrationRanges = ranges
        }
    }
    public enum Kind: String, Codable, Sendable { case highCodeRangeOverlap, lowBookCodeDuplicate }
    public struct Conflict: Codable, Sendable {
        public let kind: Kind
        public let firstIndex: Int
        public let secondIndex: Int
        public let affectedCodes: Interval
    }
    /// Ordered like the firmware's bnflist.lst: the first matching package wins.
    public static func firstMatch(code: UInt32, packages: [Package]) -> Int? {
        if code <= 65534 { return packages.firstIndex { $0.oid3BookCode == code } }
        if code <= 99999 { return nil }
        return packages.firstIndex { $0.registrationRanges.contains { code >= $0.start && code <= $0.end } }
    }
    public static func detect(_ packages: [Package]) -> [Conflict] {
        var result: [Conflict] = []
        for i in packages.indices {
            for j in packages.indices where j > i {
                let a = packages[i], b = packages[j]
                if a.oid3BookCode <= 65534, a.oid3BookCode == b.oid3BookCode {
                    result.append(Conflict(kind: .lowBookCodeDuplicate, firstIndex: i, secondIndex: j,
                                           affectedCodes: Interval(start: a.oid3BookCode, end: a.oid3BookCode)))
                }
                for x in a.registrationRanges {
                    for y in b.registrationRanges {
                        let low = max(100000, max(x.start, y.start)), high = min(x.end, y.end)
                        if low <= high { result.append(Conflict(kind: .highCodeRangeOverlap, firstIndex: i, secondIndex: j,
                                                                affectedCodes: Interval(start: low, end: high))) }
                    }
                }
            }
        }
        return result
    }
}
