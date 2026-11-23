import Foundation

/// Parameters recovered for a particular BNF book. This is not a package detector.
public struct BNFCodecParameters: Sendable {
    public let sbox: [UInt8]
    public let keys: [[UInt16]]
    public let rotations: [Int]

    public init(sbox: [UInt8], keys: [[UInt16]], rotations: [Int]) throws {
        guard sbox.count == 256, Set(sbox).count == 256 else {
            throw BNFCodecError.invalidParameters("BNF 字节置换表必须包含 256 个不同的值。")
        }
        guard keys.count == 4, keys.allSatisfy({ $0.count == 3 }) else {
            throw BNFCodecError.invalidParameters("BNF 正文参数必须包含四组、每组三个 16 位密钥。")
        }
        guard rotations.count == 3, rotations.allSatisfy({ (0..<16).contains($0) }) else {
            throw BNFCodecError.invalidParameters("BNF 轮转参数必须包含三个 0 至 15 的数。")
        }
        self.sbox = sbox
        self.keys = keys
        self.rotations = rotations
    }
}

public enum BNFCodecError: Error, LocalizedError, Sendable, Equatable {
    case invalidParameters(String)
    case invalidPageSize
    case invalidPrefixSize
    case invalidOffset
    case invalidRC6KeySize

    public var errorDescription: String? {
        switch self {
        case .invalidParameters(let message): return message
        case .invalidPageSize: return "BNF 扇区必须为 512 字节。"
        case .invalidPrefixSize: return "BNF 页前缀必须为 32 字节。"
        case .invalidOffset: return "BNF 绝对偏移必须非负、按 512 字节对齐，且不能超出整数范围。"
        case .invalidRC6KeySize: return "BNF RC6 密钥必须为 16 字节。"
        }
    }
}

/// Reversible sector transform recovered from the P19171 firmware.
/// Book layout, media boundaries and book-specific parameters must be supplied by
/// a separately validated parser. This transform does not authenticate content.
public struct BNFCodec: Sendable {
    public static let pageSize = 512
    public static let prefixSize = 32
    /// RC6-32/20/16 key from the verified P19171 reader, serialized little endian.
    public static let p19171RC6Key = Data([
        0xbe, 0x4c, 0xb6, 0x4c, 0xb0, 0x5f, 0xb0, 0x49,
        0xbb, 0x5f, 0xa9, 0x31, 0xd1, 0x30, 0xd1, 0x30
    ])

    public let parameters: BNFCodecParameters
    private let inverseSbox: [UInt8]
    private let rc6: RC6
    public private(set) var bodyStart: Int? = nil
    public private(set) var directoryLayout: BNFBook.Layout? = nil

    public init(parameters: BNFCodecParameters, rc6Key: Data = BNFCodec.p19171RC6Key) throws {
        guard rc6Key.count == 16 else { throw BNFCodecError.invalidRC6KeySize }
        self.parameters = parameters
        var inverse = [UInt8](repeating: 0, count: 256)
        for (index, value) in parameters.sbox.enumerated() {
            inverse[Int(value)] = UInt8(index)
        }
        self.inverseSbox = inverse
        self.rc6 = RC6(key: Array(rc6Key))
    }


    /// Parses the two encrypted metadata sectors from the original BNF header.
    /// Supply the beginning of the file (normally the first 64 KiB).
    /// Firmware-derived layout is currently validated for version 10 and 11 only.
    public init(fileHeader: Data) throws {
        let bytes = Array(fileHeader)
        func u16(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
        func u32(_ b: [UInt8], _ p: Int) -> UInt32 {
            UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
        }
        func invalid() -> BNFCodecError { .invalidParameters("BNF 文件头不完整或不支持；目前已验证版本 10 和 11。") }
        let signature = Array("SS_Book_Code".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
        guard bytes.count >= 0xc8, Array(bytes[0xb0..<0xc8]) == signature, [10, 11].contains(u16(bytes, 0)) else { throw invalid() }
        let cipher = RC6(key: Array(Self.p19171RC6Key))
        func decrypted(_ offset: Int, _ count: Int) throws -> [UInt8] {
            guard offset >= 0, offset <= bytes.count, count <= bytes.count - offset else { throw invalid() }
            var block = Array(bytes[offset..<offset + count])
            cipher.transform(&block, count: count, decrypt: true)
            return block
        }
        let pointer = try decrypted(16, 16)
        let base = u16(pointer, 0)
        let first = try decrypted(base, 512)
        guard base >= 512, base.isMultiple(of: 512), Array(first[4..<12]) == Array("OID70032".utf8) else { throw invalid() }
        let secondBase = base + u16(first, 0)
        guard secondBase >= base + 512, secondBase.isMultiple(of: 512) else { throw invalid() }
        let second = try decrypted(secondBase, 512)
        // Firmware XORs exactly twenty halfwords; the final twenty bytes stay raw.
        let table = second[0x36..<0x36 + 60].enumerated().map { $0.offset < 40 ? $0.element ^ 0xac : $0.element }
        let selector = Int(u32(table, 4))
        guard selector < 15 else { throw invalid() }
        let primary = u32(table, selector * 4)
        let start = Int((UInt32(u16(second, 0) + secondBase) &- primary) & 0xffff)
        guard start >= secondBase + 512, start.isMultiple(of: 512) else { throw invalid() }
        let rings = [primary, u32(second, 0x12c), u32(second, 0x130), u32(second, 0x134)]
        let keys = rings.map { value -> [UInt16] in
            let lo = UInt16(truncatingIfNeeded: value), hi = UInt16(value >> 16)
            return [lo, hi, lo ^ hi]
        }
        let params = try BNFCodecParameters(sbox: Self.firmwareSbox, keys: keys, rotations: [14, 0, 10])
        try self.init(parameters: params)
        bodyStart = start
        let playlist = u32(second, 0x1c) &- primary
        directoryLayout = BNFBook.Layout(bodyStart: start, commandOrigin: Int(u32(second, 8) &- primary), mediaTableOrigin: Int(u32(second, 0x10) &- primary), playlistOrigin: playlist == UInt32.max ? nil : Int(playlist), commandCount: Int(u32(second, 0x70) &- primary))
    }

    // Inverse table in verified P19171 firmware at file offset 0x1d6298;
    // each low byte is XOR AC. Stored here in forward direction for encoding.
    private static let firmwareSbox: [UInt8] = [90, 193, 117, 250, 119, 190, 170, 44, 33, 179, 31, 150, 200, 80, 32, 194, 125, 171, 46, 196, 215, 128, 129, 185, 121, 146, 239, 6, 2, 48, 64, 62, 4, 232, 78, 143, 180, 127, 36, 68, 201, 35, 56, 45, 210, 218, 72, 96, 173, 137, 16, 160, 73, 192, 8, 237, 112, 204, 174, 18, 140, 27, 230, 57, 41, 91, 40, 172, 76, 75, 155, 105, 109, 178, 233, 223, 79, 241, 12, 66, 85, 226, 133, 110, 205, 144, 151, 94, 134, 227, 211, 26, 111, 124, 99, 23, 42, 153, 47, 102, 202, 25, 147, 14, 252, 83, 208, 228, 217, 34, 3, 103, 165, 168, 221, 246, 88, 166, 58, 115, 104, 61, 242, 86, 10, 177, 15, 249, 97, 87, 136, 81, 118, 189, 100, 234, 186, 69, 126, 183, 148, 236, 113, 169, 55, 5, 50, 0, 184, 54, 138, 163, 22, 135, 28, 7, 38, 114, 77, 63, 154, 253, 206, 198, 101, 120, 107, 67, 220, 116, 106, 156, 213, 21, 158, 176, 251, 108, 152, 95, 43, 93, 19, 122, 145, 71, 243, 161, 9, 182, 229, 222, 52, 255, 224, 70, 225, 157, 216, 195, 197, 212, 188, 29, 164, 191, 131, 231, 65, 167, 187, 244, 24, 207, 240, 214, 17, 51, 84, 142, 13, 203, 92, 39, 141, 98, 30, 247, 1, 53, 60, 219, 235, 11, 162, 254, 74, 37, 130, 89, 149, 123, 132, 20, 59, 82, 245, 181, 159, 139, 49, 238, 209, 199, 175, 248]

    /// `absoluteOffset` is the sector's original position in the BNF file.
    /// Every media's first sector has an additional RC6 layer over all 512 bytes.
    public func decodePage(_ ciphertext: Data, absoluteOffset: Int, isMediaFirstSector: Bool = false) throws -> Data {
        guard ciphertext.count == Self.pageSize else { throw BNFCodecError.invalidPageSize }
        try checkOffset(absoluteOffset)
        var bytes = Array(ciphertext)
        if isMediaFirstSector { rc6.transform(&bytes, count: Self.pageSize, decrypt: true) }
        rc6.transform(&bytes, count: Self.prefixSize, decrypt: true)
        transformWords(&bytes, absoluteOffset: absoluteOffset, decode: true)
        return Data(bytes)
    }

    public func encodePage(_ plaintext: Data, absoluteOffset: Int, isMediaFirstSector: Bool = false) throws -> Data {
        guard plaintext.count == Self.pageSize else { throw BNFCodecError.invalidPageSize }
        try checkOffset(absoluteOffset)
        var bytes = Array(plaintext)
        transformWords(&bytes, absoluteOffset: absoluteOffset, decode: false)
        rc6.transform(&bytes, count: Self.prefixSize, decrypt: false)
        if isMediaFirstSector { rc6.transform(&bytes, count: Self.pageSize, decrypt: false) }
        return Data(bytes)
    }

    /// Decodes an ordinary page prefix after any whole-media-first-sector layer
    /// has been removed. Use decodePage for an original media first sector.
    public func decodePagePrefix(_ ciphertext: Data, absoluteOffset: Int) throws -> Data {
        guard ciphertext.count == Self.prefixSize else { throw BNFCodecError.invalidPrefixSize }
        try checkOffset(absoluteOffset)
        var bytes = Array(ciphertext)
        rc6.transform(&bytes, count: Self.prefixSize, decrypt: true)
        transformWords(&bytes, absoluteOffset: absoluteOffset, decode: true)
        return Data(bytes)
    }

    public func encodePagePrefix(_ plaintext: Data, absoluteOffset: Int) throws -> Data {
        guard plaintext.count == Self.prefixSize else { throw BNFCodecError.invalidPrefixSize }
        try checkOffset(absoluteOffset)
        var bytes = Array(plaintext)
        transformWords(&bytes, absoluteOffset: absoluteOffset, decode: false)
        rc6.transform(&bytes, count: Self.prefixSize, decrypt: false)
        return Data(bytes)
    }

    private func checkOffset(_ offset: Int) throws {
        guard offset >= (bodyStart ?? 0), offset % Self.pageSize == 0, offset <= Int.max - Self.pageSize else {
            throw BNFCodecError.invalidOffset
        }
    }

    private func transformWords(_ bytes: inout [UInt8], absoluteOffset: Int, decode: Bool) {
        let relativeOffset = absoluteOffset - (bodyStart ?? 0)
        let ring = parameters.keys[(relativeOffset / Self.pageSize) % 4]
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let position = relativeOffset + index
            let phase = (position / 2) % 6
            let keyIndex = bodyStart != nil ? phase % 3 : (phase.isMultiple(of: 2) ? phase / 2 + 1 : phase / 2) % 3
            let subtractIndex = (keyIndex + (bodyStart != nil ? 2 : 1)) % 3
            let rotation = parameters.rotations[phase % 3]
            var word = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            // Firmware deliberately omits the S-box on the first 32 bytes.
            let substitute = index >= Self.prefixSize && position.isMultiple(of: 4)
            if decode {
                word = rotateLeft16(word, rotation)
                word = (word &- ring[subtractIndex]) ^ ring[keyIndex]
                if substitute { word = (word & 0xff00) | UInt16(inverseSbox[Int(word & 255)]) }
            } else {
                if substitute { word = (word & 0xff00) | UInt16(parameters.sbox[Int(word & 255)]) }
                word = (word ^ ring[keyIndex]) &+ ring[subtractIndex]
                word = rotateLeft16(word, (16 - rotation) & 15)
            }
            bytes[index] = UInt8(truncatingIfNeeded: word)
            bytes[index + 1] = UInt8(word >> 8)
        }
    }
}

private func rotateLeft16(_ word: UInt16, _ count: Int) -> UInt16 {
    let shift = count & 15
    guard shift != 0 else { return word }
    return (word << shift) | (word >> (16 - shift))
}

private struct RC6: Sendable {
    let schedule: [UInt32]

    init(key: [UInt8]) {
        var words = stride(from: 0, to: 16, by: 4).map { Self.read(key, $0) }
        var table = (0..<44).map { UInt32(0xb7e15163) &+ (UInt32($0) &* 0x9e3779b9) }
        var a: UInt32 = 0, b: UInt32 = 0
        var i = 0, j = 0
        for _ in 0..<132 {
            a = Self.rotate(table[i] &+ a &+ b, by: 3)
            table[i] = a
            b = Self.rotate(words[j] &+ a &+ b, by: a &+ b)
            words[j] = b
            i = (i + 1) % 44
            j = (j + 1) % 4
        }
        schedule = table
    }

    func transform(_ bytes: inout [UInt8], count: Int, decrypt: Bool) {
        for offset in stride(from: 0, to: count, by: 16) {
            var a = Self.read(bytes, offset), b = Self.read(bytes, offset + 4)
            var c = Self.read(bytes, offset + 8), d = Self.read(bytes, offset + 12)
            if decrypt {
                c = c &- schedule[43]
                a = a &- schedule[42]
                for round in stride(from: 20, through: 1, by: -1) {
                    (a, b, c, d) = (d, a, b, c)
                    let u = Self.rotate(d &* ((d &* 2) &+ 1), by: 5)
                    let t = Self.rotate(b &* ((b &* 2) &+ 1), by: 5)
                    c = Self.rotate(c &- schedule[round * 2 + 1], by: 0 &- t) ^ u
                    a = Self.rotate(a &- schedule[round * 2], by: 0 &- u) ^ t
                }
                d = d &- schedule[1]
                b = b &- schedule[0]
            } else {
                b = b &+ schedule[0]
                d = d &+ schedule[1]
                for round in 1...20 {
                    let t = Self.rotate(b &* ((b &* 2) &+ 1), by: 5)
                    let u = Self.rotate(d &* ((d &* 2) &+ 1), by: 5)
                    a = Self.rotate(a ^ t, by: u) &+ schedule[round * 2]
                    c = Self.rotate(c ^ u, by: t) &+ schedule[round * 2 + 1]
                    (a, b, c, d) = (b, c, d, a)
                }
                a = a &+ schedule[42]
                c = c &+ schedule[43]
            }
            for (index, value) in [a, b, c, d].enumerated() {
                for byte in 0..<4 { bytes[offset + index * 4 + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
            }
        }
    }

    private static func read(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
            UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func rotate(_ value: UInt32, by count: UInt32) -> UInt32 {
        let shift = Int(count & 31)
        guard shift != 0 else { return value }
        return (value << shift) | (value >> (32 - shift))
    }
}

extension BNFCodec {
    /// Header-only RC6 operation for the audited template writer. Body pages use
    /// encodePage instead; confusing the two layers would corrupt metadata.
    func headerBlock(_ data: Data, decrypt: Bool) throws -> Data {
        guard !data.isEmpty, data.count.isMultiple(of: 16) else { throw BNFCodecError.invalidPrefixSize }
        var bytes = Array(data)
        rc6.transform(&bytes, count: bytes.count, decrypt: decrypt)
        return Data(bytes)
    }
}
