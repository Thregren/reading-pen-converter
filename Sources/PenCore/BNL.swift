import Foundation

/// Parameters for reading and writing the supported BNL format.
public struct BNLContext: Sendable {
    public static let supportedFirmwareSHA256 = "9f7fff5f0fd7c38f5cdd2a0ba5bea57641c3c7b6097433a076b2924129ef650d"
    let table1: [UInt8]
    let table2: [UInt8]

    init(table1: [UInt8], table2: [UInt8]) {
        self.table1 = table1
        self.table2 = table2
    }

    /// Reads the profile from a supplied firmware image for compatibility and comparison.
    public init(firmware: Data) throws {
        guard firmware.sha256 == Self.supportedFirmwareSHA256 else {
            throw PenError.invalid("当前 BNL 解码器需要已验证的🐛二代 v103 startup.bin 固件。")
        }
        func table(_ address: Int) throws -> [UInt8] {
            let start = (address - 0x400000) * 2
            return try (0..<256).map { UInt8(truncatingIfNeeded: try firmware.u16(start + $0 * 2)) }
        }
        table1 = try table(0x42ddcc)
        table2 = try table(0x42decc)
    }
}

public struct BNLRoute: Codable, Sendable, Equatable {
    public let code: UInt32
    public let index: UInt32?
    public let playlistOffset: Int?
    public let mediaIDs: [Int]
}

public struct BNLMedia: Codable, Sendable, Equatable {
    public let id: Int
    public let offset: Int
    public let allocatedLength: Int
    public let codec: UInt8
}

public struct BNLExportedMedia: Codable, Sendable {
    public let media: BNLMedia
    public let filename: String
    public let bytes: Int
    public let sha256: String
    public let mp3Frames: Int?
    public let zeroPaddingRemoved: Int
}

public struct BNLDecodedManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let sourceFilename: String
    public let sourceSHA256: String
    /// Profile provenance, kept under its original JSON key for existing manifests.
    public let firmwareSHA256: String
    public let routes: [BNLRoute]
    public let media: [BNLExportedMedia]
    public let limitations: [String]
}

public struct BNLBook: Sendable {
    public let sourceSHA256: String
    public let routes: [BNLRoute]
    public let media: [BNLMedia]
    let data: Data
    let audioKeys: [UInt8]
    let context: BNLContext
    let pointerKeys: (UInt8, UInt8)
    let mediaTable: Int

    static func xor(_ value: UInt8, _ key: UInt8) -> UInt8 {
        let result = value ^ key
        return result != key && value != 0 && value != 255 && value != key && result != 255 ? result : value
    }
    static func key(_ value: UInt8) -> UInt8 { ((value &- 0x16) ^ 0x5a) &+ 0x63 }
    static func rol3(_ value: UInt8) -> UInt8 { (value &<< 3) | (value >> 5) }
    static func decodeByte(_ value: UInt8, _ first: UInt8, _ second: UInt8) -> UInt8 {
        rol3(xor(xor(value &- 2, first), second) &- 0x20)
    }

    static func ror3(_ value: UInt8) -> UInt8 { (value >> 3) | (value &<< 5) }
    static func encodeByte(_ value: UInt8, _ first: UInt8, _ second: UInt8) -> UInt8 {
        xor(xor(ror3(value) &+ 0x20, second), first) &+ 2
    }
    static func swapBytes(_ value: UInt32) -> UInt32 {
        ((value & 0x00ff00ff) << 8) | ((value & 0xff00ff00) >> 8)
    }
    static func decodePointer(_ raw: UInt32, _ first: UInt8, _ second: UInt8) -> UInt32 {
        var value = raw
        let added = value &+ 0x12345678
        if ![0, UInt32.max, 0x12345678].contains(value) && added != 0 && added != .max { value = added }
        let difference = value &- 0x47584202
        if value != 0 && value != .max && difference != 0 && difference != .max { value = difference }
        value = swapBytes(value)
        return ~(0..<4).reduce(UInt32(0)) { result, index in
            result | UInt32(decodeByte(UInt8(truncatingIfNeeded: value >> (index * 8)), first, second)) << (index * 8)
        }
    }
    static func encodePointer(_ plain: UInt32, _ first: UInt8, _ second: UInt8) throws -> UInt32 {
        let inverted = ~plain
        let bytes = (0..<4).reduce(UInt32(0)) { result, index in
            result | UInt32(encodeByte(UInt8(truncatingIfNeeded: inverted >> (index * 8)), first, second)) << (index * 8)
        }
        let value = swapBytes(bytes)
        let candidates: [UInt32] = [value &+ 0x47584202 &- 0x12345678, value &+ 0x47584202,
                                    value &- 0x12345678, value, 0, .max, 0x12345678]
        guard let encoded = candidates.first(where: {
            let decoded = $0 == 0 || $0 == .max ? $0 : decodePointer($0, first, second)
            return decoded == plain
        }) else {
            throw PenError.invalid("BNL DWORD 无法安全逆编码。")
        }
        return encoded
    }

    public init(data: Data, context: BNLContext) throws {
        guard data.count >= 0x204,
              Array(data[0x1c0..<0x1c9]).map({ $0 ^ 0x80 }) == Array("Chomptech".utf8) else {
            throw PenError.invalid("不是已验证的🐛 BNL 变体。")
        }
        let selector = Int(try data.u32(0x164) & 255)
        let first = Self.key(context.table1[2]), second = Self.key(context.table2[selector])
        func bytes(_ word: UInt32) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { result, index in
                result | UInt32(Self.decodeByte(UInt8(truncatingIfNeeded: word >> (index * 8)), first, second)) << (index * 8)
            }
        }
        let tag = bytes(try data.u32(0x1b8))
        guard tag == 0x47584202 else { throw PenError.invalid("BNL 的 GX B 模式 2 标记未通过验证。") }
        func pointer(_ offset: Int) throws -> Int {
            let raw = try data.u32(offset)
            if raw == 0 || raw == UInt32.max { return Int(raw) }
            return Int(Self.decodePointer(raw, first, second))
        }
        let table = try pointer(4), count = try pointer(0x20)
        guard table >= 0x204, count > 0, count <= 65536, table <= data.count - count * 8 else {
            throw PenError.invalid("BNL 媒体表越界。")
        }
        var tracks: [BNLMedia] = []
        for id in 0..<count {
            let offset = try pointer(table + id * 8), metadata = try pointer(table + id * 8 + 4)
            let length = (metadata & 0xffffff) * 512
            if length == 0 { continue }
            guard offset >= table + count * 8, length <= data.count, offset <= data.count - length else {
                throw PenError.invalid("BNL 媒体 \(id) 超出文件边界。")
            }
            tracks.append(BNLMedia(id: id, offset: offset, allocatedLength: length, codec: UInt8(truncatingIfNeeded: metadata >> 24)))
        }
        let routeTable = try pointer(0)
        let begin = UInt32(try pointer(0x194)), end = UInt32(try pointer(0x198))
        guard begin <= end, UInt64(end) - UInt64(begin) < 1_000_000 else {
            throw PenError.invalid("BNL 注册范围无效。")
        }
        let slots = Int(end - begin) + 1, mappingEnd = Int(try data.u32(0x19c))
        let mappingStart = mappingEnd - slots * 4
        guard routeTable >= 0x200, mappingStart > routeTable, mappingEnd <= table else {
            throw PenError.invalid("BNL 注册映射越界。")
        }
        let trackIDs = Set(tracks.map(\.id))
        var expected: UInt32 = 0, routes: [BNLRoute] = []
        for slot in 0..<slots {
            let value = try data.u32(mappingStart + slot * 4)
            if value == UInt32.max {
                routes.append(BNLRoute(code: begin + UInt32(slot), index: nil, playlistOffset: nil, mediaIDs: []))
                continue
            }
            guard value == expected else { throw PenError.invalid("BNL 注册映射不是已验证的索引序列。") }
            expected += 1
            let playlist = try pointer(routeTable + (Int(value) + 1) * 4)
            guard playlist >= mappingEnd, playlist <= table - 2 else { throw PenError.invalid("BNL 播放表越界。") }
            let number = Int(try data.u16(playlist))
            guard number <= (table - playlist - 2) / 2 else { throw PenError.invalid("BNL 播放列表长度越界。") }
            let ids = try (0..<number).map { Int(try data.u16(playlist + 2 + $0 * 2)) }
            guard ids.allSatisfy({ trackIDs.contains($0) }) else { throw PenError.invalid("BNL 播放表引用了不存在的媒体。") }
            routes.append(BNLRoute(code: begin + UInt32(slot), index: value, playlistOffset: playlist, mediaIDs: ids))
        }
        guard routeTable + (Int(expected) + 1) * 4 == mappingStart else {
            throw PenError.invalid("BNL 指针数量与注册映射不一致。")
        }
        let seed = Int(try data.u32(0x160) & 255)
        self.audioKeys = (0..<16).map { Self.key(context.table1[(seed + $0) & 255]) }
        self.context = context
        self.pointerKeys = (first, second)
        self.mediaTable = table
        self.sourceSHA256 = data.sha256
        self.data = data
        self.routes = routes
        self.media = tracks
    }

    public func allocatedAudio(_ track: BNLMedia) throws -> Data {
        guard media.contains(where: { $0.id == track.id && $0.offset == track.offset && $0.allocatedLength == track.allocatedLength }), track.codec == 1 else {
            throw PenError.invalid("当前仅支持已验证的 BNL MP3 媒体。")
        }
        let shift = UInt8(truncatingIfNeeded: track.offset >> 8)
        let position = (0..<4).reduce(UInt8(0)) { $0 &+ UInt8(truncatingIfNeeded: track.offset >> ($1 * 8)) }
        var result = Data(count: track.allocatedLength)
        for index in 0..<track.allocatedLength {
            let increment = UInt8(truncatingIfNeeded: index)
            var value = Self.xor(data[track.offset + index], position &+ increment)
            value = (value & 0xdd) | ((value & 2) << 4) | ((value & 0x20) >> 4)
            value = Self.rol3(value &+ 0x20)
            result[index] = Self.xor(value, audioKeys[index & 15] &+ shift &+ increment)
        }
        return result
    }

    public func extract(sourceFilename: String, to destination: URL) throws -> BNLDecodedManifest {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw PenError.invalid("输出目录已存在，请选择新名称。")
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".penconvert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            var exported: [BNLExportedMedia] = []
            for track in media {
                let allocated = try allocatedAudio(track)
                let bounds = MP3Structure.bounds(allocated)
                let output = bounds.map { allocated.subdata(in: 0..<$0.contentEnd) } ?? allocated
                let filename = String(format: "%04X", track.id) + (bounds == nil ? ".bin" : ".mp3")
                try output.write(to: staging.appendingPathComponent(filename), options: .withoutOverwriting)
                exported.append(BNLExportedMedia(media: track, filename: filename, bytes: output.count, sha256: output.sha256, mp3Frames: bounds?.frames, zeroPaddingRemoved: bounds?.padding ?? 0))
            }
            let manifest = BNLDecodedManifest(schemaVersion: 1, sourceFilename: sourceFilename, sourceSHA256: sourceSHA256,
                firmwareSHA256: BNLContext.supportedFirmwareSHA256, routes: routes, media: exported,
                limitations: ["数值注册路由已解析，尚未用实机验证纸面点阵。", "无法完整验证为 MP3 的媒体保留为 .bin；跨品牌重建尚未实现。"])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            try FileManager.default.moveItem(at: staging, to: destination)
            return manifest
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}

public struct BNLRebuildReport: Codable, Sendable {
    public let sourceSHA256: String
    public let outputSHA256: String
    public let outputBytes: Int
    public let changedMediaIDs: [Int]
    public let media: [BNLExportedMedia]
    public let limitations: [String]
}

extension BNLBook {
    static func encodeAudio(_ plain: Data, offset: Int, keys: [UInt8]) -> Data {
        let shift = UInt8(truncatingIfNeeded: offset >> 8)
        let position = (0..<4).reduce(UInt8(0)) { $0 &+ UInt8(truncatingIfNeeded: offset >> ($1 * 8)) }
        var result = Data(count: plain.count)
        for index in 0..<plain.count {
            let increment = UInt8(truncatingIfNeeded: index)
            var value = xor(plain[index], keys[index & 15] &+ shift &+ increment)
            value = ror3(value) &- 0x20
            value = (value & 0xdd) | ((value & 2) << 4) | ((value & 0x20) >> 4)
            result[index] = xor(value, position &+ increment)
        }
        return result
    }

    /// Rebuilds this exact local mode-2 template with same-ID replacement MP3s.
    /// Unknown structure and routes remain byte-preserved; no hardware acceptance claim.
    public func rebuild(decodedDirectory: URL, to destination: URL) throws -> BNLRebuildReport {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw PenError.invalid("输出文件已存在。") }
        let root = decodedDirectory.resolvingSymlinksInPath().standardizedFileURL
        let manifest = try JSONDecoder().decode(BNLDecodedManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        guard manifest.schemaVersion == 1, manifest.sourceSHA256 == sourceSHA256,
              manifest.firmwareSHA256 == BNLContext.supportedFirmwareSHA256, manifest.routes == routes else {
            throw PenError.invalid("清单的模板、固件或注册路由不匹配；当前不支持修改路由。")
        }
        guard manifest.media.count == media.count, Set(manifest.media.map { $0.media.id }).count == media.count,
              Set(manifest.media.map { $0.media.id }) == Set(media.map(\.id)) else {
            throw PenError.invalid("清单媒体 ID 集合与模板不一致。")
        }
        let ordered = media.sorted { $0.offset < $1.offset }
        guard let first = ordered.first else { throw PenError.invalid("模板没有媒体。") }
        guard first.offset >= 8, mediaTable <= first.offset - 8,
              media.allSatisfy({ $0.id >= 0 && $0.id <= (first.offset - mediaTable - 8) / 8 }) else {
            throw PenError.invalid("模板媒体表侵入音频区，拒绝重封包。")
        }
        var end = first.offset
        for track in ordered {
            guard track.codec == 1, track.offset % 512 == 0, track.offset == end else {
                throw PenError.invalid("模板音频区存在未知格式、间隙或重叠，拒绝重封包。")
            }
            end += track.allocatedLength
        }
        guard end == data.count else { throw PenError.invalid("模板含未知尾部，拒绝重封包。") }
        let records = Dictionary(uniqueKeysWithValues: manifest.media.map { ($0.media.id, $0) })
        var prefix = data.subdata(in: 0..<first.offset), body = Data()
        var expected: [Int: Data] = [:], exported: [BNLExportedMedia] = [], changed: [Int] = []
        func writePointer(_ field: Int, value: Int, previous: Int) throws {
            if value == previous { return } // retain original sentinel/raw spelling
            guard let plain = UInt32(exactly: value) else { throw PenError.invalid("BNL 偏移超出 DWORD 范围。") }
            let encoded = try Self.encodePointer(plain, pointerKeys.0, pointerKeys.1)
            for index in 0..<4 { prefix[field + index] = UInt8(truncatingIfNeeded: encoded >> (index * 8)) }
        }
        for track in ordered {
            guard let record = records[track.id], record.media == track else { throw PenError.invalid("清单媒体属性被修改。") }
            let allocated = try allocatedAudio(track)
            let oldBounds = MP3Structure.bounds(allocated)
            let oldAudio = oldBounds.map { allocated.subdata(in: 0..<$0.contentEnd) } ?? allocated
            guard record.sha256 == oldAudio.sha256, record.bytes == oldAudio.count,
                  record.mp3Frames == oldBounds?.frames, record.zeroPaddingRemoved == (oldBounds?.padding ?? 0) else {
                throw PenError.invalid("清单的原始音频身份不匹配。")
            }
            guard !record.filename.isEmpty, record.filename != ".", record.filename != "..",
                  !record.filename.contains("/"), !record.filename.contains("\\") else {
                throw PenError.invalid("音频文件名必须位于导出目录内。")
            }
            let inputURL = root.appendingPathComponent(record.filename).resolvingSymlinksInPath().standardizedFileURL
            guard inputURL.deletingLastPathComponent().path == root.path else { throw PenError.invalid("音频链接指向导出目录外。") }
            let plain = try Data(contentsOf: inputURL)
            let unchanged = plain == oldAudio, bounds = MP3Structure.bounds(plain)
            guard !plain.isEmpty, unchanged || bounds != nil else {
                throw PenError.invalid("替换音频必须是完整 MP3；未知 .bin 仅支持原样保留。")
            }
            if !unchanged { _ = try MP3Decoder.validate(plain) }
            guard plain.count <= 0xffffff * 512 else { throw PenError.invalid("音频超过 BNL 扇区长度限制。") }
            let length = unchanged ? track.allocatedLength : ((plain.count + 511) / 512) * 512
            let offset = prefix.count + body.count
            let oldMetadata = try data.u32(mediaTable + track.id * 8 + 4)
            let originalMetadata = oldMetadata == 0 || oldMetadata == .max ? oldMetadata : Self.decodePointer(oldMetadata, pointerKeys.0, pointerKeys.1)
            let metadata = (Int(originalMetadata) & 0xff000000) | (length / 512)
            try writePointer(mediaTable + track.id * 8, value: offset, previous: track.offset)
            try writePointer(mediaTable + track.id * 8 + 4, value: metadata, previous: Int(originalMetadata))
            var padded = plain; padded.append(Data(repeating: 0, count: length - plain.count))
            body.append(Self.encodeAudio(padded, offset: offset, keys: audioKeys))
            expected[track.id] = padded
            if !unchanged { changed.append(track.id) }
            let updated = BNLMedia(id: track.id, offset: offset, allocatedLength: length, codec: track.codec)
            exported.append(BNLExportedMedia(media: updated, filename: record.filename, bytes: plain.count,
                sha256: plain.sha256, mp3Frames: bounds?.frames, zeroPaddingRemoved: length - plain.count))
        }
        var output = prefix; output.append(body)
        let verified = try BNLBook(data: output, context: context)
        guard verified.routes == routes, verified.media == exported.sorted(by: { $0.media.id < $1.media.id }).map(\.media) else {
            throw PenError.invalid("重建后路由或媒体表回读不一致。")
        }
        for track in verified.media {
            guard let reference = expected[track.id], try verified.allocatedAudio(track) == reference else {
                throw PenError.invalid("重建后音频回读不一致。")
            }
            if changed.contains(track.id), MP3Structure.bounds(reference) == nil { throw PenError.invalid("重建后 MP3 验证失败。") }
        }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".penconvert-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try output.write(to: staging, options: .withoutOverwriting)
        try manager.moveItem(at: staging, to: destination)
        return BNLRebuildReport(sourceSHA256: sourceSHA256, outputSHA256: output.sha256, outputBytes: output.count,
            changedMediaIDs: changed, media: exported, limitations: ["仅支持已验证模式 2 模板的同 ID 音频替换。", "保留原注册路由；尚未证明实机接受或 BNF 互转。"])
    }
}
