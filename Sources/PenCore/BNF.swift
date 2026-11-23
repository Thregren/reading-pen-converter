import Foundation

/// Parses only the explicit registration metadata found in the supplied BNF files.
/// Code ranges have not yet been mapped to a decoded physical OID or audio stream.
public struct BNFMetadata: Sendable, Codable {
    public struct CodeRange: Sendable, Codable {
        public let start: UInt32
        public let end: UInt32
        public var count: UInt64 { UInt64(end) - UInt64(start) + 1 }
    }
    public let version: UInt16
    public let identifierHex: String
    public let markerOffset: Int
    public let ranges: [CodeRange]
    public let trailingMetadataWord: UInt32?

    public static func read(_ data: Data) throws -> BNFMetadata {
        let marker = Data("SS_Book_Code".utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
        guard data.count >= 0xd6, let found = data.range(of: marker, in: 0..<Swift.min(data.count, 4096)) else {
            throw PenError.invalid("未找到 BNF 的 SS_Book_Code 标记。")
        }
        let countOffset = found.upperBound + 12
        let count = Int(try data.u16(countOffset))
        guard count <= 1024, countOffset + 2 <= data.count - count * 8 else {
            throw PenError.invalid("BNF 码段表超出文件边界。")
        }
        var ranges: [CodeRange] = []
        for index in 0..<count {
            let offset = countOffset + 2 + index * 8
            let start = try data.u32(offset), end = try data.u32(offset + 4)
            guard start <= end else { throw PenError.invalid("BNF 码段起点大于终点。") }
            ranges.append(CodeRange(start: start, end: end))
        }
        // 0xEE is preserved as an unknown metadata word, observed only for this layout.
        let trailing = found.lowerBound == 0xb0 && count == 1 ? try? data.u32(0xee) : nil
        return BNFMetadata(version: try data.u16(0), identifierHex: data[2..<10].map { String(format: "%02x", $0) }.joined(), markerOffset: found.lowerBound, ranges: ranges, trailingMetadataWord: trailing)
    }
}
