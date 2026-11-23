import Foundation

/// Experimental public NOD V1 route; hardware compatibility is not yet verified.
public struct NODRoute: Sendable, Equatable {
    public let code: UInt32
    public let audio: Data
    public init(code: UInt32, audio: Data) { self.code = code; self.audio = Data(audio) }
}

public struct NODOpenParameters: Sendable {
    public let bookID: UInt32
    public let userID: String
    public let bookTime: String
    public let secret64: Data
    public let extInfo: Data
    public init(bookID: UInt32, userID: String, bookTime: String, secret64: Data, extInfo: Data = Data()) {
        self.bookID = bookID; self.userID = userID; self.bookTime = bookTime
        self.secret64 = Data(secret64); self.extInfo = Data(extInfo)
    }
}

/// Restricted, offline public NOD V1 codec derived by static analysis of official
/// libnobV3.dll SHA256 56bb665e5931398281d126c402db3a568c7e72abbffadfcff6ac736f22fd9037.
/// Header/key/index/audio primitives: RVA 38C0/3940/3A40/3AD0/3B70/3BE0;
/// writer RVA 87690. Public reader skips external authorization at RVA CFDC.
/// Only type-1 single-primary-audio cover-mode books are supported. This is not
/// a BNF codec, and no target pen has yet validated generated NOD files.
public struct NODOpenBook: Sendable {
    public let routes: [NODRoute]
    public let coverAudio: Data
    public let coverCodes: [UInt32]
    public let bookID: UInt32
    public let userID: String
    public let bookTime: String
    public let extInfo: Data
    public static let experimentalHardwareUnverified = true

    // Same 64-byte vector at writer RVA DD5C8 and reader D1AF0 in pinned DLL.
    static let verification = Data("abcdefghijklmnopqrstuvwxyz1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ=-".utf8)
    static let fileLimit = 0xf7ffffff
    static let maximumRoutes = 100_000

    static func put(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    static func random(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: .min ... .max) }) }
    static func xor(_ data: Data, _ key: Data, phase: Int = 0) -> Data {
        Data(data.enumerated().map { $0.element ^ key[(phase + $0.offset) & 63] })
    }
    // CRC table at RVA CF220 mostly matches reflected EDB88320, but entry
    // 150 is 256C3671 rather than 196C3671. Preserve the actual vendor constant.
    // Unlike zlib, the
    // native loop uses signed SAR eax,8 and initial 0, without final inversion.
    static let crcTable: [UInt32] = (0..<256).map { i in
        var value = UInt32(i)
        for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) != 0 ? 0xedb88320 : 0) }
        return i == 150 ? 0x256c3671 : value
    }
    static func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for byte in data {
            let shifted = UInt32(bitPattern: Int32(bitPattern: value) >> 8)
            value = shifted ^ crcTable[Int((value ^ UInt32(byte)) & 255)]
        }
        return value
    }
    static func digest(_ data: Data) -> Data {
        var result = Data(repeating: 0, count: 128)
        for (i, byte) in data.enumerated() { result[i & 127] ^= byte }
        return result
    }
    static func decodeHeader(_ raw: Data) -> Data {
        var h = raw
        for i in 0x20..<0x164 { h[i] ^= h[0x10 + (i & 15)] }
        for i in 0..<64 { h[0x100 + i] ^= h[0x58 + (i & 15)] }
        return h
    }
    static func encodeHeader(_ plain: Data, nonce: Data) -> Data {
        var h = plain
        h.replaceSubrange(0x10..<0x20, with: nonce)
        for i in 0..<64 { h[0x100 + i] ^= h[0x58 + (i & 15)] }
        for i in 0x20..<0x164 { h[i] ^= h[0x10 + (i & 15)] }
        put(&h, 0x160, crc(Data(h.prefix(0x160))))
        return h
    }
    static func decodeIndex(_ raw: Data, position: Int, key: Data) -> Data {
        var r = raw
        for i in 8..<0x34 { r[i] ^= key[(position + i) & 63] }
        for i in 4..<0x34 { r[i] ^= r[i & 3] }
        return r
    }
    static func encodeIndex(_ plain: Data, position: Int, key: Data, nonce: Data) -> Data {
        var r = plain
        r.replaceSubrange(0..<4, with: nonce)
        for i in 4..<0x34 { r[i] ^= r[i & 3] }
        for i in 8..<0x34 { r[i] ^= key[(position + i) & 63] }
        return r
    }
    static func validateAudio(_ audio: Data, label: String, seen: inout Set<Data>) throws {
        if seen.contains(audio) { return }
        do { _ = try MP3Decoder.validate(audio) }
        catch { throw PenError.invalid("\(label) 不是可完整解码的 MP3：\(error.localizedDescription)") }
        seen.insert(audio)
    }

    public init(data source: Data) throws {
        let data = Data(source)
        guard data.count >= 0x1e4, data.count <= Self.fileLimit,
              data.prefix(3) == Data("NOD".utf8), data[8..<10] == Data("V1".utf8),
              Self.crc(Data(data.prefix(0x160))) == (try data.u32(0x160)) else {
            throw PenError.invalid("NOD V1 标记或头部 CRC 无效。")
        }
        let h = Self.decodeHeader(Data(data.prefix(0x164)))
        guard Int(try h.u32(0x88)) == data.count,
              Self.digest(Data(data[0x164..<(data.count - 128)])) == data.suffix(128) else {
            throw PenError.invalid("NOD 长度或尾部摘要无效。")
        }
        guard h[0x54] == 1, h[0x55] == 1 else {
            throw PenError.invalid("当前只支持实验性公开 NOD V1 封面模式。")
        }
        let key = Data(h[0x100..<0x140])
        guard Self.xor(Data(data[0x164..<0x1a4]), key) == Self.verification else {
            throw PenError.invalid("NOD 密钥校验块无效。")
        }
        let index = Int(try h.u32(0x68)), count = Int(try h.u32(0x6c)), start = Int(try h.u32(0x8c))
        guard count > 0, count <= Self.maximumRoutes, index >= 0x1a4, index <= start,
              start <= data.count - 128, count <= (start - index) / 0x34,
              index + count * 0x34 == start else { throw PenError.invalid("NOD 索引越界。") }
        func clip(_ offset: Int, _ length: Int, lower: Int, upper: Int) throws -> Data {
            guard length > 0, offset >= lower, offset <= upper, length <= upper - offset else {
                throw PenError.invalid("NOD 音频或播放列表超出文件边界。")
            }
            return Data(data[offset..<(offset + length)])
        }
        var seen = Set<Data>()
        func audio(_ offset: Int, _ length: Int, label: String) throws -> Data {
            let value = Self.xor(try clip(start + offset, length, lower: start, upper: data.count - 128), key, phase: offset)
            try Self.validateAudio(value, label: label, seen: &seen)
            return value
        }
        var parsed: [NODRoute] = [], previous: UInt32 = 0
        for i in 0..<count {
            let pos = index + i * 0x34
            let r = Self.decodeIndex(Data(data[pos..<(pos + 0x34)]), position: pos, key: key)
            let oid = try r.u32(4)
            guard oid > previous, r[0x28] == 1, r[0x29] == 0, r[0x2a] == 1,
                  try r.u32(12) == 0x6c, r[16..<40].allSatisfy({ $0 == 0 }),
                  r[0x2b..<0x34].allSatisfy({ $0 == 0 }) else {
                throw PenError.invalid("NOD 含未支持或未排序的点读码记录。")
            }
            previous = oid
            let m = try clip(Int(r.u32(8)), 0x6c, lower: 0x1a4, upper: index)
            guard m[8..<0x60].allSatisfy({ $0 == 0 }), m[0x60] == 2,
                  m[0x61..<0x6c].allSatisfy({ $0 == 0 }) else {
                throw PenError.invalid("NOD 点读码 \(oid) 不是已支持的单音轨播放列表。")
            }
            parsed.append(NODRoute(code: oid, audio: try audio(Int(m.u32(0)), Int(m.u32(4)), label: "NOD 点读码 \(oid)")))
        }
        var covers: [UInt32] = []
        for i in 0..<8 { let oid = try h.u32(0x90 + i * 4); if oid != 0 { covers.append(oid) } }
        guard !covers.isEmpty, Set(covers).count == covers.count,
              Set(covers).isDisjoint(with: Set(parsed.map(\.code))) else { throw PenError.invalid("NOD 封面点读码为空、重复或与正文冲突。") }
        func text(_ offset: Int, _ length: Int) throws -> String {
            let bytes = h[offset..<(offset + length)].prefix(while: { $0 != 0 })
            guard !bytes.isEmpty, let result = String(data: Data(bytes), encoding: .utf8) else {
                throw PenError.invalid("NOD 书籍字段不是有效 UTF-8。")
            }
            return result
        }
        let extSize = Int(try h.u32(0x144)), extOffset = Int(try h.u32(0x140))
        extInfo = extSize == 0 ? Data() : Self.xor(try clip(extOffset, extSize, lower: 0x1a4, upper: index), key, phase: extOffset)
        coverAudio = try audio(Int(h.u32(0xb0)), Int(h.u32(0xb4)), label: "NOD 封面音频")
        routes = parsed; coverCodes = covers; bookID = try h.u32(0x30)
        userID = try text(0x34, 32); bookTime = try text(0x58, 16)
    }

    /// Builds in memory and reparses the entire output, including complete MP3
    /// decoding. The caller owns file creation/no-overwrite/atomic-write policy.
    public static func build(routes: [NODRoute], coverAudio: Data, coverCodes: [UInt32], parameters: NODOpenParameters) throws -> Data {
        let coverAudio = Data(coverAudio)
        let user = Data(parameters.userID.utf8), time = Data(parameters.bookTime.utf8)
        guard !user.isEmpty, user.count <= 31, !user.contains(0), !time.isEmpty,
              time.count <= 15, !time.contains(0), parameters.secret64.count == 64 else {
            throw PenError.invalid("NOD 参数需要 1–31 字节 userID、1–15 字节 bookTime 和恰好 64 字节本地 secret。")
        }
        let ordered = routes.sorted { $0.code < $1.code }, codes = Set(routes.map(\.code))
        guard !routes.isEmpty, routes.count <= maximumRoutes, codes.count == routes.count, !codes.contains(0),
              !coverCodes.isEmpty, coverCodes.count <= 8, Set(coverCodes).count == coverCodes.count,
              !coverCodes.contains(0), codes.isDisjoint(with: Set(coverCodes)) else {
            throw PenError.invalid("NOD 正文和封面点读码必须非空、不重复且互不重叠。")
        }
        // Bound all fixed structures before allocating or converting sizes to UInt32.
        let overhead = 0x164 + 64 + 127 + 128 + ordered.count * (0x6c + 0x34)
        guard parameters.extInfo.count <= fileLimit - overhead,
              coverAudio.count <= fileLimit - overhead - parameters.extInfo.count else {
            throw PenError.invalid("NOD 音频或扩展字段超过长度限制。")
        }
        var seen = Set<Data>()
        try validateAudio(coverAudio, label: "封面音频", seen: &seen)
        for route in ordered { try validateAudio(route.audio, label: "点读码 \(route.code) 音频", seen: &seen) }
        var h = Data(repeating: 0, count: 0x164)
        h.replaceSubrange(0..<3, with: "NOD".utf8); h.replaceSubrange(8..<10, with: "V1".utf8)
        h.replaceSubrange(0x20..<0x28, with: "20250617".utf8); put(&h, 0x30, parameters.bookID)
        h.replaceSubrange(0x34..<(0x34 + user.count), with: user); h[0x54] = 1; h[0x55] = 1
        h.replaceSubrange(0x58..<(0x58 + time.count), with: time)
        let key = Data((0..<64).map { parameters.secret64[$0] ^ UInt8(truncatingIfNeeded: parameters.bookID >> (($0 & 3) * 8)) ^ time[$0 % time.count] })
        h.replaceSubrange(0x100..<0x140, with: key)
        for (i, code) in coverCodes.enumerated() { put(&h, 0x90 + i * 4, code) }
        var audio = coverAudio
        put(&h, 0xb4, UInt32(coverAudio.count))
        var locations = [Data: (Int, Int)](); locations[coverAudio] = (0, coverAudio.count)
        var pairs: [(Int, Int)] = []
        for route in ordered {
            if let location = locations[route.audio] { pairs.append(location) }
            else {
                guard route.audio.count <= fileLimit - overhead - parameters.extInfo.count - audio.count else { throw PenError.invalid("NOD 音频总长度过大。") }
                let location = (audio.count, route.audio.count)
                locations[route.audio] = location; pairs.append(location); audio.append(route.audio)
            }
        }
        var body = xor(verification, key); body.append(random(Int.random(in: 0..<128)))
        func position() -> Int { 0x164 + body.count }
        if !parameters.extInfo.isEmpty {
            guard parameters.extInfo.count <= fileLimit - position() else { throw PenError.invalid("NOD 扩展字段过大。") }
            put(&h, 0x140, UInt32(position())); put(&h, 0x144, UInt32(parameters.extInfo.count))
            body.append(xor(parameters.extInfo, key, phase: position()))
        }
        var records: [Data] = []
        for (i, route) in ordered.enumerated() {
            var m = Data(repeating: 0, count: 0x6c)
            put(&m, 0, UInt32(pairs[i].0)); put(&m, 4, UInt32(pairs[i].1)); m[0x60] = 2
            var r = Data(repeating: 0, count: 0x34)
            put(&r, 4, route.code); put(&r, 8, UInt32(position())); put(&r, 12, 0x6c)
            r[0x28] = 1; r[0x2a] = 1; records.append(r); body.append(m)
        }
        put(&h, 0x68, UInt32(position())); put(&h, 0x6c, UInt32(records.count))
        for r in records { body.append(encodeIndex(r, position: position(), key: key, nonce: random(4))) }
        put(&h, 0x8c, UInt32(position()))
        guard audio.count <= fileLimit - position() - 128 else { throw PenError.invalid("NOD 文件超过已验证长度限制。") }
        body.append(xor(audio, key)); put(&h, 0x88, UInt32(position() + 128))
        var output = encodeHeader(h, nonce: random(16)); output.append(body); output.append(digest(body))
        let check = try NODOpenBook(data: output)
        guard check.routes == ordered, check.coverAudio == coverAudio, check.coverCodes == coverCodes,
              check.bookID == parameters.bookID, check.userID == parameters.userID,
              check.bookTime == parameters.bookTime, check.extInfo == parameters.extInfo else {
            throw PenError.invalid("NOD 写入后重新解析的播放语义不一致。")
        }
        return output
    }
}
