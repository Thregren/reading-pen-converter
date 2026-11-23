import Foundation

/// Firmware-backed subset, not a claim that every v11 book has these controls.
public enum BNFTemplateProfile {
    public static let identifier = "p19171-v11-single-group-bank"
    public static let selectorBehavior = "当前 v11 单组模板的两个选择器保留为组 0 / bank 0，均无提示音；跨格式音频导出若省略它们，不代表设备控制行为等价。"

    public static func validate(_ data: Data) throws {
        let data = Data(data)
        func fail() -> PenError { .invalid("BNF 模板不符合已验证的 v11 单组单 bank 条件；不能安全重建布局。") }
        guard data.count >= 512, try data.u16(0) == 11,
              try data.u32(8) == .max, try data.u32(12) == .max else { throw fail() }
        let codec = try BNFCodec(fileHeader: data), book = try BNFBook(data: data)
        let pointer = try codec.headerBlock(data.subdata(in: 16..<32), decrypt: true)
        let firstBase = Int(try pointer.u16(0))
        guard firstBase >= 512, firstBase <= data.count - 512 else { throw fail() }
        let first = try codec.headerBlock(data.subdata(in: firstBase..<firstBase+512), decrypt: true)
        let secondBase = firstBase + Int(try first.u16(0))
        guard secondBase >= firstBase + 512, secondBase <= data.count - 512 else { throw fail() }
        let header = try codec.headerBlock(data.subdata(in: secondBase..<secondBase+512), decrypt: true)
        let table = Data(header[0x36..<0x72].enumerated().map { $0.offset < 40 ? $0.element ^ 0xac : $0.element })
        let selector = Int(try table.u32(4))
        guard selector < 15 else { throw fail() }
        let key = try table.u32(selector * 4)
        func field16(_ p: Int) throws -> UInt16 { UInt16(truncatingIfNeeded: UInt32(try header.u16(p)) &- key) }
        func field32(_ p: Int) throws -> UInt32 { try header.u32(p) &- key }
        guard try field16(4) == 1, try field16(0x62) == 12,
              try field16(0x15c) == 1, try field16(0x15e) == 0,
              try field32(0x68) == 1 else { throw fail() }
        for p in [0xc,0x14,0x18,0x20,0x64,0x6c] {
            guard try field32(p) == .max else { throw fail() }
        }
        let start = book.layout.bodyStart
        let body = try codec.decodePage(data.subdata(in: start..<start+512), absoluteOffset: start)
        guard try body.u16(0) == 512, try body.u16(2) == 0x6666,
              try body.u32(4) == .max, try body.u16(8) == .max,
              book.ranges.count == 2, book.ranges[0].start == 1, book.ranges[0].end == 2,
              book.ranges[1].start >= 100000,
              try data.u16(0xd4) == 1, try data.u32(0xd6) == book.ranges[1].start,
              try data.u32(0xda) == book.ranges[1].end,
              book.commands.count >= 4 else { throw fail() }
        // BNFBook also validates this preamble; keep the template contract explicit.
        let rangePage = try codec.decodePage(data.subdata(in: start+512..<start+1024), absoluteOffset: start+512)
        guard rangePage.prefix(14) == Data([0,2,1,0,0,0,0xf8,3,0,0,8,0,0,0]) else { throw fail() }
        // The two actual selector rows, including opaque fields, must match.
        for (index, type) in [(0, UInt16(30)), (1, UInt16(3))] {
            let row = book.commands[index]
            guard row.oid == UInt32(index + 1), row.type == type,
                  row.reference == .max, row.randomWord == .max, row.trailingWord == 0 else { throw fail() }
        }
        guard let end = book.commands.last, end.oid == nil, end.type == 10,
              end.reference == .max, end.randomWord == .max, end.trailingWord == .max else { throw fail() }
    }
}
