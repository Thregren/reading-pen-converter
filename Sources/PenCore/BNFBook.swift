import Foundation

/// A decoded BNF directory. Unknown header bytes and command fields are retained
/// in the original package; a same-layout edit never synthesizes a new header.
public struct BNFBook: Sendable {
    public struct Layout: Sendable {
        public let bodyStart: Int
        public let commandOrigin: Int
        public let mediaTableOrigin: Int
        public let playlistOrigin: Int?
        /// Number of code-indexed commands, excluding the terminal type-10 row.
        public let commandCount: Int
        public init(bodyStart: Int, commandOrigin: Int, mediaTableOrigin: Int,
                    playlistOrigin: Int?, commandCount: Int) {
            self.bodyStart = bodyStart; self.commandOrigin = commandOrigin
            self.mediaTableOrigin = mediaTableOrigin; self.playlistOrigin = playlistOrigin
            self.commandCount = commandCount
        }
    }
    public struct Media: Sendable, Codable {
        public let index: Int
        public let offset: Int
        public let allocationLength: Int
    }
    public struct Command: Sendable, Codable {
        public let index: Int
        public let oid: UInt32?
        public let offset: Int
        public let type: UInt16
        public let reference: UInt32
        public let randomWord: UInt32
        public let trailingWord: UInt16
        public let mediaIndices: [Int]?
        public var isHighFlagged: Bool { type & 0x8000 != 0 }
        /// Structural flag only; it does not prove that a recording/control action is disposable.
        public var isUnused: Bool { isHighFlagged }
    }
    public struct AudioRoute: Sendable, Codable {
        public let oid: UInt32
        public let mediaIndices: [Int]
    }
    public let layout: Layout
    public let ranges: [BNFMetadata.CodeRange]
    public let media: [Media]
    public let commands: [Command]
    private let original: Data
    private let codec: BNFCodec

    public var sourceSHA256: String { original.sha256 }
    public init(data: Data) throws {
        let codec = try BNFCodec(fileHeader: data)
        guard let layout = codec.directoryLayout else { throw PenError.invalid("BNF 头中没有完整的目录位置。") }
        try self.init(data: data, codec: codec, layout: layout)
    }

    public init(data: Data, codec: BNFCodec, layout: Layout) throws {
        let data = Data(data) // Normalize Data slices to zero-based indices.
        guard data.count % 512 == 0, layout.bodyStart >= 512,
              layout.bodyStart <= data.count - 1024,
              layout.bodyStart % 512 == 0,
              layout.commandCount > 0, layout.commandCount <= 2_000_000 else {
            throw PenError.invalid("BNF 文件长度或目录范围无效。")
        }
        let reader = BNFDirectoryReader(data: data, codec: codec)
        let rangeBase = layout.bodyStart + Int(try reader.read(layout.bodyStart, 2).u16(0))
        let marker = Data([0,2,1,0,0,0,0xf8,3,0,0,8,0,0,0])
        guard try reader.read(rangeBase, 14) == marker else {
            throw PenError.invalid("BNF 点读码范围目录标记不受支持。")
        }
        let rangeCount = Int(try reader.read(rangeBase + 14, 2).u16(0))
        guard rangeCount > 0, rangeCount <= 1024 else { throw PenError.invalid("BNF 码段数量无效。") }
        var ranges: [BNFMetadata.CodeRange] = []
        var total: UInt64 = 0
        for i in 0..<rangeCount {
            let pair = try reader.read(rangeBase + 16 + i * 8, 8)
            let start = try pair.u32(0), end = try pair.u32(4)
            guard start <= end, !ranges.contains(where: { start <= $0.end && end >= $0.start }) else {
                throw PenError.invalid("BNF 点读码范围重叠或倒置。")
            }
            total += UInt64(end) - UInt64(start) + 1
            ranges.append(BNFMetadata.CodeRange(start: start, end: end))
        }
        guard total == UInt64(layout.commandCount) else { throw PenError.invalid("BNF 码段总数与命令数量不一致。") }
        let mediaCount = Int(try reader.word(layout.mediaTableOrigin) ^ 0x66666666)
        guard mediaCount > 0, mediaCount <= 1_000_000 else { throw PenError.invalid("BNF 媒体数量无效。") }
        var offsets: [Int] = []
        for i in 0..<mediaCount {
            offsets.append(Int(try reader.word(layout.mediaTableOrigin + 4 + i * 4) ^ 0x66666666))
        }
        let lastLength = Int(try reader.word(layout.mediaTableOrigin + 4 + mediaCount * 4) ^ 0x66666666)
        var media: [Media] = []
        for i in offsets.indices {
            let length = i + 1 < offsets.count ? offsets[i + 1] - offsets[i] : lastLength
            guard offsets[i] >= layout.bodyStart, offsets[i] % 512 == 0,
                  length > 0, length % 512 == 0, offsets[i] <= data.count,
                  length <= data.count - offsets[i] else { throw PenError.invalid("BNF 媒体分配表越界或重叠。") }
            media.append(Media(index: i, offset: offsets[i], allocationLength: length))
        }
        // Directory pages must not be interpreted with the media-first-sector rule.
        let commandLength = (layout.commandCount + 1) * 12
        guard layout.commandOrigin >= layout.bodyStart,
              layout.commandOrigin <= data.count - commandLength else { throw PenError.invalid("BNF 命令表超出文件。") }
        let directorySpans = [layout.bodyStart..<(layout.bodyStart + 2), rangeBase..<(rangeBase + 16 + rangeCount * 8),
                              layout.mediaTableOrigin..<(layout.mediaTableOrigin + 8 + mediaCount * 4),
                              layout.commandOrigin..<(layout.commandOrigin + commandLength)]
        for i in directorySpans.indices {
            for j in directorySpans.indices where j > i {
                guard !directorySpans[i].overlaps(directorySpans[j]) else { throw PenError.invalid("BNF 目录节相互重叠。") }
            }
        }
        guard !media.contains(where: { item in directorySpans.contains(where: { $0.overlaps(item.offset..<(item.offset + item.allocationLength)) }) }) else {
            throw PenError.invalid("BNF 目录与媒体区域重叠。")
        }
        var commands: [Command] = []
        var rangeIndex = 0
        var oid = ranges[0].start
        for i in 0...layout.commandCount {
            let offset = layout.commandOrigin + i * 12
            let row = try reader.read(offset, 12)
            let type = try row.u16(0), reference = try row.u32(2)
            var indices: [Int]? = nil
            if type == 2 {
                if reference == UInt32.max { indices = [] }
                else if reference & 0x80000000 == 0 { indices = [Int(reference)] }
                else {
                    guard let base = layout.playlistOrigin, base >= layout.bodyStart, base <= data.count else { throw PenError.invalid("BNF 命令引用播放列表，但文件没有播放列表目录。") }
                    let target = base + Int(reference & 0x7fffffff) * 4
                    var list: [Int] = []; var terminated = false
                    for j in 0...30 {
                        let wordOffset = target + j * 4
                        let span = wordOffset..<(wordOffset + 4)
                        guard !directorySpans.contains(where: { $0.overlaps(span) }),
                              !media.contains(where: { span.overlaps($0.offset..<($0.offset + $0.allocationLength)) }) else {
                            throw PenError.invalid("BNF 播放列表引用与其他目录或媒体区域重叠。")
                        }
                        let value = try reader.word(wordOffset)
                        if value == UInt32.max { terminated = true; break }
                        guard j < 30 else { break }
                        list.append(Int(value))
                    }
                    guard terminated else { throw PenError.invalid("BNF 播放列表缺少结束标记或超过 30 项。") }
                    indices = list
                }
                guard indices!.allSatisfy({ $0 >= 0 && $0 < mediaCount }) else { throw PenError.invalid("BNF 播放列表包含不受支持的媒体标志或越界编号。") }
            }
            commands.append(Command(index: i, oid: i == layout.commandCount ? nil : oid,
                offset: offset, type: type, reference: reference, randomWord: try row.u32(6),
                trailingWord: try row.u16(10), mediaIndices: indices))
            if i < layout.commandCount - 1 {
                if oid == ranges[rangeIndex].end { rangeIndex += 1; oid = ranges[rangeIndex].start }
                else { oid += 1 }
            }
        }
        guard commands.last?.type == 10 else { throw PenError.invalid("BNF 命令表末尾不是已知结束记录。") }
        self.layout = layout; self.ranges = ranges; self.media = media; self.commands = commands
        self.original = data; self.codec = codec
    }

    /// Strict by default: recording/control/game commands are not audio routes.
    /// Explicit omission is limited to the validated v11 single-group profile.
    public func audioRoutes(allowSystemControls: Bool = false) throws -> [AudioRoute] {
        if allowSystemControls && commands.contains(where: { $0.oid != nil && ($0.type == 3 || $0.type == 30) }) {
            try BNFTemplateProfile.validate(original)
        }
        var routes: [AudioRoute] = []
        for command in commands where command.oid != nil {
            guard !command.isHighFlagged else { throw PenError.invalid("BNF 包含语义未确认的高位标记命令（点读码 \(command.oid!)）；不能静默丢弃后转换。") }
            if command.type == 2, let indices = command.mediaIndices {
                routes.append(AudioRoute(oid: command.oid!, mediaIndices: indices))
            } else if allowSystemControls && ((command.oid == 1 && command.type == 30) || (command.oid == 2 && command.type == 3)) {
                continue
            } else {
                throw PenError.invalid("BNF 点读码 \(command.oid!) 的命令类型 \(command.type) 尚不能转换为 BNL 音频路由。")
            }
        }
        return routes
    }

    /// Includes original allocation padding; callers must identify audio length.
    public func decodedMediaAllocation(at index: Int) throws -> Data {
        guard media.indices.contains(index) else { throw PenError.invalid("BNF 媒体编号越界。") }
        let item = media[index]; var output = Data(); output.reserveCapacity(item.allocationLength)
        for relative in stride(from: 0, to: item.allocationLength, by: 512) {
            let q = item.offset + relative
            output.append(try codec.decodePage(original.subdata(in: q..<(q + 512)), absoluteOffset: q, isMediaFirstSector: relative == 0))
        }
        return output
    }

    /// Returns only the verified MPEG stream, excluding metadata tags.
    /// APE/ID3v1 allocation trailers and FF padding are excluded after validation.
    public func validatedAudio(at index: Int) throws -> Data {
        let allocation = try decodedMediaAllocation(at: index)
        guard let bounds = try Self.strictAudioBounds(allocation) else {
            throw PenError.invalid("BNF 媒体 \(index) 的音频结构或尾部格式未通过严格验证。")
        }
        let audio = allocation.subdata(in: bounds.start..<bounds.end)
        _ = try MP3Decoder.validate(audio)
        return audio
    }

    /// Same-allocation writer. Unedited bytes, including unknown header fields,
    /// command random words and trailing package bytes, remain exactly original.
    public func repacked(mediaAllocations: [Int: Data] = [:], directReferences: [UInt32: Int] = [:]) throws -> Data {
        var output = original
        for (index, plaintext) in mediaAllocations {
            guard media.indices.contains(index), plaintext.count == media[index].allocationLength else {
                throw PenError.invalid("BNF 原布局写回要求媒体分配长度保持一致。")
            }
            let item = media[index]
            for relative in stride(from: 0, to: plaintext.count, by: 512) {
                let q = item.offset + relative
                let cipher = try codec.encodePage(plaintext.subdata(in: relative..<(relative + 512)), absoluteOffset: q, isMediaFirstSector: relative == 0)
                output.replaceSubrange(q..<(q + 512), with: cipher)
            }
        }
        let reader = BNFDirectoryReader(data: original, codec: codec)
        var editedPages: [Int: Data] = [:]
        for (oid, index) in directReferences {
            guard media.indices.contains(index), let command = commands.first(where: { $0.oid == oid }), command.type == 2 else {
                throw PenError.invalid("只能修改已存在音频命令的有效媒体引用。")
            }
            let value = UInt32(index)
            for byte in 0..<4 {
                let position = command.offset + 2 + byte, page = (position / 512) * 512
                if editedPages[page] == nil { editedPages[page] = try reader.read(page, 512) }
                editedPages[page]![position - page] = UInt8(truncatingIfNeeded: value >> (byte * 8))
            }
        }
        for (page, plain) in editedPages {
            output.replaceSubrange(page..<(page + 512), with: try codec.encodePage(plain, absoluteOffset: page))
        }
        return output
    }
}

private final class BNFDirectoryReader {
    let data: Data
    let codec: BNFCodec
    var pages: [Int: Data] = [:]
    init(data: Data, codec: BNFCodec) { self.data = data; self.codec = codec }
    func read(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 512, count >= 0, offset <= data.count, count <= data.count - offset else {
            throw PenError.invalid("BNF 目录字段越界。")
        }
        var output = Data(); output.reserveCapacity(count)
        var cursor = offset
        while cursor < offset + count {
            let base = cursor / 512 * 512
            guard base <= data.count - 512 else { throw PenError.invalid("BNF 目录页不完整。") }
            if pages[base] == nil { pages[base] = try codec.decodePage(data.subdata(in: base..<(base + 512)), absoluteOffset: base) }
            let length = min(offset + count - cursor, 512 - cursor % 512)
            output.append(pages[base]!.subdata(in: (cursor % 512)..<(cursor % 512 + length)))
            cursor += length
        }
        return output
    }
    func word(_ offset: Int) throws -> UInt32 { try read(offset, 4).u32(0) }
}

extension BNFBook {
    public struct ExtractedMedia: Sendable, Codable {
        public let index: Int
        public let filename: String
        public let allocationFilename: String
        public let audioBytes: Int
        public let mp3Frames: Int?
        public let sha256: String
        public let note: String?
    }
    public struct ExtractionManifest: Sendable, Codable {
        public let schema: String
        public let sourceFilename: String
        public let sourceSHA256: String
        public let media: [ExtractedMedia]
        public let commands: [Command]
        public let ranges: [BNFMetadata.CodeRange]
        public let limitations: [String]
    }

    /// Exports validated MPEG audio plus lossless allocation sidecars. The full
    /// command manifest is a faithful directory, not a claim of BNL equivalence.
    @discardableResult
    public func extract(sourceFilename: String, to destination: URL) throws -> ExtractionManifest {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw PenError.invalid("导出目录已存在，请选择新的目录。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".bnf-extract-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        var committed = false
        defer { if !committed { try? fm.removeItem(at: staging) } }
        var entries: [ExtractedMedia] = []
        for item in media {
            let allocation = try decodedMediaAllocation(at: item.index)
            let stem = String(format: "%04d", item.index), allocationName = stem + ".allocation.bin"
            try allocation.write(to: staging.appendingPathComponent(allocationName), options: .atomic)
            if let bounds = try Self.strictAudioBounds(allocation) {
                let audio = allocation.subdata(in: 0..<bounds.end)
                _ = try MP3Decoder.validate(audio)
                let filename = stem + ".mp3"
                try audio.write(to: staging.appendingPathComponent(filename), options: .atomic)
                entries.append(ExtractedMedia(index: item.index, filename: filename, allocationFilename: allocationName,
                    audioBytes: audio.count, mp3Frames: bounds.frames,
                    sha256: audio.sha256, note: nil))
            } else {
                entries.append(ExtractedMedia(index: item.index, filename: allocationName, allocationFilename: allocationName,
                    audioBytes: 0, mp3Frames: nil,
                    sha256: allocation.sha256,
                    note: "分配区已完整解密，但音频结构或尾部格式不受支持；保留原始字节，未生成 MP3。"))
            }
        }
        let manifest = ExtractionManifest(schema: "bnf-extraction-v1", sourceFilename: sourceFilename,
            sourceSHA256: sourceSHA256, media: entries, commands: commands, ranges: ranges,
            limitations: ["原始系统、录音及其他命令保留在清单中，不代表已转换为 BNL。", "allocation.bin 保留音频标签和分配区尾部，可用于原布局无损写回；MP3 仅包含验证过的音频帧。", "尚未进行点读笔实机验证。"])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: staging, to: destination); committed = true
        return manifest
    }

    static func strictAudioBounds(_ data: Data) throws -> (start: Int, end: Int, frames: Int)? {
        var cursor = 0
        if data.starts(with: [0x49, 0x44, 0x33]) {
            guard data.count >= 10, [2,3,4].contains(data[3]), data[6..<10].allSatisfy({ $0 < 128 }) else { return nil }
            cursor = 10 + data[6..<10].reduce(0) { ($0 << 7) | Int($1) }
            if data[3] == 4 && data[5] & 16 != 0 { cursor += 10 }
            guard cursor <= data.count else { return nil }
        }
        let audioStart = cursor
        var frames = 0
        var configuration: UInt32?
        while let length = MP3Structure.frameLength(data, cursor), length <= data.count - cursor {
            let header = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[cursor + $1]) }
            // Version, layer and sampling rate may not change mid-allocation.
            let config = header & 0x001e0c00
            if let configuration, configuration != config { return nil }
            configuration = config
            cursor += length; frames += 1
        }
        guard frames >= 3 else { return nil }
        let frameEnd = cursor
        if cursor <= data.count - 128, data.subdata(in: cursor..<(cursor + 3)) == Data("TAG".utf8) { cursor += 128 }
        if cursor <= data.count - 32, data.subdata(in: cursor..<(cursor + 8)) == Data("APETAGEX".utf8) {
            // APEv2 header + items + footer. Tag size includes footer, not header.
            let size = Int(try data.u32(cursor + 12)), itemCount = Int(try data.u32(cursor + 16))
            guard try data.u32(cursor + 8) == 2000, size >= 32, itemCount <= 10000,
                  size <= data.count - cursor - 32, try data.u32(cursor + 20) == 0xa0000000 else { return nil }
            let footer = cursor + size
            guard data.subdata(in: footer..<(footer + 8)) == Data("APETAGEX".utf8),
                  try data.u32(footer + 8) == 2000, try data.u32(footer + 12) == UInt32(size),
                  try data.u32(footer + 16) == UInt32(itemCount), try data.u32(footer + 20) == 0x80000000 else { return nil }
            var itemCursor = cursor + 32
            for _ in 0..<itemCount {
                guard itemCursor <= footer - 8 else { return nil }
                let valueLength = Int(try data.u32(itemCursor)); itemCursor += 8
                guard let keyEnd = data[itemCursor..<footer].firstIndex(of: 0), keyEnd > itemCursor,
                      valueLength <= footer - keyEnd - 1 else { return nil }
                itemCursor = keyEnd + 1 + valueLength
            }
            guard itemCursor == footer else { return nil }
            cursor = footer + 32
        }
        guard data.count - cursor < 512, data[cursor...].allSatisfy({ $0 == 0xff }) else { return nil }
        return (audioStart, frameEnd, frames)
    }
}
