import Foundation

/// Experimental v11 writer based on an audited single-group v11 profile. It creates
/// new section positions; opaque device/book identity fields remain the template's.
public enum BNFWriter {
    public static let templateProfile = BNFTemplateProfile.identifier
    public static let limitations = [
        "模板配置：" + BNFTemplateProfile.identifier,
        BNFTemplateProfile.selectorBehavior,
        "新音频记录固定使用播放模式 1，保留列表顺序；原轮换或随机播放行为不保留。",
        "实验性小时候的🐸 v11 新布局写出，仅接受通过单组单 bank 字段验证的模板；尚未实机验证。",
        "数值点读码和播放顺序保留，不保证另一品牌能识别原书纸面点阵。",
        "保留模板的未知书籍身份及设备字段，尚未证明与原模板同时装笔时不会发生识别冲突。",
        "当前 v11 模板的点读码 1 / 2 是选择组 0 的无音频控制；保留这两行，输入码段未映射点写成无音频记录。"
    ]

    public static func write(template: Data, points: [BNLWritePoint], audio: [Data]) throws -> Data {
        let template = Data(template)
        try BNFTemplateProfile.validate(template)
        let book = try BNFBook(data: template), codec = try BNFCodec(fileHeader: template)
        let ordered = points.sorted { $0.code < $1.code }
        guard let first = ordered.first, let last = ordered.last, first.code >= 100000,
              Set(ordered.map(\.code)).count == ordered.count,
              UInt64(last.code) - UInt64(first.code) < 1_000_000,
              !audio.isEmpty, audio.count <= 65535,
              ordered.allSatisfy({ $0.mediaIDs.count <= 30 && $0.mediaIDs.allSatisfy { audio.indices.contains($0) } }),
              book.commands.count >= 4, book.commands[0].oid == 1, book.commands[0].type == 30,
              book.commands[1].oid == 2, book.commands[1].type == 3,
              let prototype = book.commands.first(where: { $0.type == 2 }),
              book.commands.last?.type == 10 else { throw PenError.invalid("BNF 输入码段、播放表或模板系统记录不受支持。") }
        for bytes in audio {
            guard !bytes.isEmpty, bytes.count <= Int(UInt32.max), MP3Structure.bounds(bytes) != nil else { throw PenError.invalid("BNF 音频必须为完整 MP3。") }
            _ = try MP3Decoder.validate(bytes)
        }
        func aligned(_ n: Int) -> Int { (n + 511) / 512 * 512 }
        func read(_ q: Int, _ n: Int) throws -> Data {
            var bytes = Data()
            for page in stride(from: q / 512 * 512, to: aligned(q + n), by: 512) {
                bytes.append(try codec.decodePage(template.subdata(in: page..<(page + 512)), absoluteOffset: page))
            }
            return bytes.subdata(in: (q % 512)..<(q % 512 + n))
        }
        func put32(_ data: inout Data, _ at: Int, _ value: UInt32) {
            for i in 0..<4 { data[at+i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
        }
        func put16(_ data: inout Data, _ at: Int, _ value: UInt16) {
            data[at] = UInt8(truncatingIfNeeded: value); data[at+1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func append32(_ data: inout Data, _ value: UInt32) {
            for i in 0..<4 { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        let start = book.layout.bodyStart, range = start + 512, command = start + 1024
        let count = Int(last.code - first.code) + 1
        let playlistBase = aligned(command + (count + 3) * 12)
        let byCode = Dictionary(uniqueKeysWithValues: ordered.map { ($0.code, $0.mediaIDs) })
        let prototypeData = try read(prototype.offset, 12)
        var playlist = Data(), rows = try read(book.layout.commandOrigin, 24)
        for code in first.code...last.code {
            let ids = byCode[code] ?? []
            let reference: UInt32
            if ids.isEmpty { reference = .max }
            else if ids.count == 1 { reference = UInt32(ids[0]) }
            else {
                reference = 0x80000000 | UInt32(playlist.count / 4)
                for id in ids { append32(&playlist, UInt32(id)) }
                append32(&playlist, .max)
            }
            var row = prototypeData
            put32(&row, 2, reference)
            // e09f764: mode 0 cycles one item per tap; 2 shuffles; 3 randomizes.
            // Mode 1 leaves the ordered list intact. Never inherit GoGo mode 0.
            put16(&row, 10, 1)
            rows.append(row)
        }
        rows.append(try read(book.commands.last!.offset, 12))
        let table = aligned(playlistBase + max(1, playlist.count))
        let audioBase = aligned(table + (audio.count + 2) * 4)
        var offsets: [Int] = [], cursor = audioBase
        for bytes in audio {
            offsets.append(cursor); cursor += aligned(bytes.count)
            guard cursor <= Int(UInt32.max) else { throw PenError.invalid("BNF 文件超过 32 位偏移范围。") }
        }
        var plain = Data(repeating: 255, count: cursor - start)
        func store(_ q: Int, _ data: Data) { plain.replaceSubrange((q-start)..<(q-start+data.count), with: data) }
        var bodyHeader = try read(start, 512); put16(&bodyHeader, 0, 512); store(start, bodyHeader)
        let oldRange = start + Int(try read(start, 2).u16(0))
        var rangeHeader = try read(oldRange, 512)
        put16(&rangeHeader, 14, 2); put32(&rangeHeader, 16, 1); put32(&rangeHeader, 20, 2)
        put32(&rangeHeader, 24, first.code); put32(&rangeHeader, 28, last.code); store(range, rangeHeader)
        store(command, rows); store(playlistBase, playlist)
        var tableData = Data(); append32(&tableData, UInt32(audio.count) ^ 0x66666666)
        for offset in offsets { append32(&tableData, UInt32(offset) ^ 0x66666666) }
        append32(&tableData, UInt32(aligned(audio.last!.count)) ^ 0x66666666); store(table, tableData)
        for (i, bytes) in audio.enumerated() { store(offsets[i], bytes) }
        var result = template.subdata(in: 0..<start)
        let firstSectors = Set(offsets)
        for q in stride(from: start, to: cursor, by: 512) {
            result.append(try codec.encodePage(plain.subdata(in: (q-start)..<(q-start+512)), absoluteOffset: q, isMediaFirstSector: firstSectors.contains(q)))
        }
        let pointer = try codec.headerBlock(template.subdata(in: 16..<32), decrypt: true)
        let firstBase = Int(try pointer.u16(0))
        let firstHeader = try codec.headerBlock(template.subdata(in: firstBase..<(firstBase+512)), decrypt: true)
        let secondBase = firstBase + Int(try firstHeader.u16(0))
        var header = try codec.headerBlock(template.subdata(in: secondBase..<(secondBase+512)), decrypt: true)
        let keyTable = Data(header[0x36..<(0x36+60)].enumerated().map { $0.offset < 40 ? $0.element ^ 0xac : $0.element })
        let selector = Int(try keyTable.u32(4)); guard selector < 15 else { throw PenError.invalid("BNF 模板密钥选择越界。") }
        let key = try keyTable.u32(selector * 4)
        for (at, value) in [(8, UInt32(command)), (0x10, UInt32(table)), (0x1c, playlist.isEmpty ? .max : UInt32(playlistBase)), (0x70, UInt32(count + 2))] {
            put32(&header, at, value &+ key)
        }
        result.replaceSubrange(secondBase..<(secondBase+512), with: try codec.headerBlock(header, decrypt: false))
        put32(&result, 0xd6, first.code); put32(&result, 0xda, last.code)
        let verified = try BNFBook(data: result)
        let actual = try verified.audioRoutes(allowSystemControls: true)
        guard actual.count == count, actual.allSatisfy({ $0.mediaIndices == (byCode[$0.oid] ?? []) }),
              verified.media.count == audio.count else { throw PenError.invalid("BNF 写出后的码段或播放顺序回读不一致。") }
        for i in audio.indices {
            let bytes = try verified.decodedMediaAllocation(at: i)
            guard bytes.prefix(audio[i].count) == audio[i], bytes.dropFirst(audio[i].count).allSatisfy({ $0 == 255 }) else {
                throw PenError.invalid("BNF 写出后的媒体回读不一致。")
            }
        }
        return result
    }
}
