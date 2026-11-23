import Foundation

public struct BNLWritePoint: Sendable, Equatable {
    public let code: UInt32
    public let mediaIDs: [Int]
    public init(code: UInt32, mediaIDs: [Int]) { self.code = code; self.mediaIDs = mediaIDs }
}

/// Audio-only mode-2 writer. Numeric codes are retained; physical OID recognition
/// and acceptance by a pen are not established by a successful build.
public enum BNLWriter {
    // Restricts opaque device flags and unknown fields to the single independently audited header.
    public static let supportedTemplateHeaderSHA256 = "61154153e23396f9982401de4e6c0f57d863af3fdae17bb8512caea25bc945c0"
    public static let limitations = [
        "仅写出已核对的🐛 v103 模式 2 音频布局，尚未实机验证。",
        "保留输入的数值点读码；不保证另一品牌笔能识别原书纸面点阵。",
        "沿用已验证模板的设备标志及尚未解释的字段；模板的系统提示音及游戏功能不复制。"
    ]
    static let eventFields = [0x10,0x14,0x18,0x24,0x28,0x2c,0x38,0x3c,0x44,
        0x48,0x4c,0x50,0x54,0x58,0x5c,0x60,0x64,0x68,0x6c,0x78,0x80,0x84,
        0x88,0x8c,0x94,0x98,0xc0,0xc4,0xc8,0xcc,0xd0,0xd4,0xd8,0xdc,
        0x154,0x158,0x15c,0x168,0x16c,0x170,0x174]

    public static func write(template: BNLBook, points: [BNLWritePoint], audio: [Data]) throws -> Data {
        try build(header: template.data.subdata(in: 0..<512), context: template.context,
                  points: points, audio: audio)
    }

    static func build(header: Data, context: BNLContext, points: [BNLWritePoint], audio: [Data]) throws -> Data {
        guard header.count == 512, header.sha256 == supportedTemplateHeaderSHA256 else {
            throw PenError.invalid("音频写出目前仅接受已核对的 The Journey 原始 BNL 模板头；其他模板尚未证明所有字段用途。")
        }
        let ordered = points.sorted { $0.code < $1.code }
        guard let first = ordered.first, let last = ordered.last, ordered.count <= 65535,
              Set(ordered.map(\.code)).count == ordered.count,
              UInt64(last.code) - UInt64(first.code) < 1_000_000,
              !audio.isEmpty, audio.count <= 65536,
              ordered.allSatisfy({ $0.mediaIDs.count <= 65535 && $0.mediaIDs.allSatisfy { audio.indices.contains($0) } }) else {
            throw PenError.invalid("BNL 路由重复、数量过多、码段跨度过大或媒体引用无效。")
        }
        for bytes in audio {
            guard !bytes.isEmpty, bytes.count <= 0xffffff * 512, MP3Structure.bounds(bytes) != nil else {
                throw PenError.invalid("BNL 音频写出只接受完整 MP3，不接受录音容器或未知媒体。")
            }
            _ = try MP3Decoder.validate(bytes)
        }
        let selector = Int(try header.u32(0x164) & 255)
        let k1 = BNLBook.key(context.table1[2]), k2 = BNLBook.key(context.table2[selector])
        let seed = Int(try header.u32(0x160) & 255)
        let audioKeys = (0..<16).map { BNLBook.key(context.table1[(seed + $0) & 255]) }
        var output = header
        func append16(_ value: Int) { output.append(UInt8(truncatingIfNeeded: value)); output.append(UInt8(truncatingIfNeeded: value >> 8)) }
        func append32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { output.append(UInt8(truncatingIfNeeded: value >> shift)) } }
        func raw(_ field: Int, _ value: UInt32) { for i in 0..<4 { output[field+i] = UInt8(truncatingIfNeeded: value >> (i*8)) } }
        func pointer(_ field: Int, _ value: Int) throws {
            guard let word = UInt32(exactly: value) else { throw PenError.invalid("BNL 文件超过 32 位偏移范围。") }
            raw(field, try BNLBook.encodePointer(word, k1, k2))
        }
        let table = output.count
        output.append(Data(repeating: 0, count: (ordered.count + 1) * 4))
        raw(table, .max); raw(0x150, .max)
        try pointer(0, table); try pointer(0x1c, ordered.count << 16)
        // All 30 audited original packages store the route-pointer payload
        // length here, excluding the reserved slot at index zero.
        try pointer(0x190, ordered.count * 4)
        let byCode = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.code, UInt32($0.offset)) })
        for code in first.code...last.code { append32(byCode[code] ?? .max) }
        let mappingEnd = output.count
        raw(0x19c, UInt32(mappingEnd)); try pointer(0x194, Int(first.code)); try pointer(0x198, Int(last.code))
        var ranges: [(UInt32, UInt32)] = []
        for point in ordered {
            if let previous = ranges.last, UInt64(previous.1) + 1 == UInt64(point.code) { ranges[ranges.count-1].1 = point.code }
            else { ranges.append((point.code, point.code)) }
        }
        guard ranges.count <= 65535 else { throw PenError.invalid("BNL 码段数量过多。") }
        append16(ranges.count)
        for range in ranges { append32(range.0) }
        for range in ranges { append32(range.0 == range.1 ? 0 : range.1) }
        // Every known event pointer is relocated; no old template media ID survives.
        for field in eventFields { try pointer(field, output.count); append16(0) }
        try pointer(0x1b4, output.count); append16(ordered.count)
        for id in 1...ordered.count { append16(id) }
        for (index, point) in ordered.enumerated() {
            try pointer(table + (index + 1) * 4, output.count)
            append16(point.mediaIDs.count)
            for id in point.mediaIDs { append16(id) }
        }
        let mediaTable = output.count
        try pointer(4, mediaTable); try pointer(0xa0, mediaTable); try pointer(0x20, audio.count)
        output.append(Data(repeating: 0, count: audio.count * 8))
        output.append(Data(repeating: 0, count: (512 - output.count % 512) % 512))
        for (id, bytes) in audio.enumerated() {
            let offset = output.count, length = ((bytes.count + 511) / 512) * 512
            guard offset <= Int(UInt32.max) - length else { throw PenError.invalid("BNL 文件超过 32 位偏移范围。") }
            try pointer(mediaTable + id * 8, offset)
            try pointer(mediaTable + id * 8 + 4, 0x01000000 | (length / 512))
            var padded = bytes; padded.append(Data(repeating: 0, count: length - bytes.count))
            output.append(BNLBook.encodeAudio(padded, offset: offset, keys: audioKeys))
        }
        let readback = try BNLBook(data: output, context: context)
        let actual = readback.routes.filter { $0.index != nil }.map { BNLWritePoint(code: $0.code, mediaIDs: $0.mediaIDs) }
        guard actual == ordered, readback.media.count == audio.count else { throw PenError.invalid("BNL 写出后的路由或媒体数量验证失败。") }
        for track in readback.media {
            var expected = audio[track.id]
            expected.append(Data(repeating: 0, count: track.allocatedLength - expected.count))
            guard try readback.allocatedAudio(track) == expected else { throw PenError.invalid("BNL 写出后的音频验证失败。") }
        }
        return output
    }
}
