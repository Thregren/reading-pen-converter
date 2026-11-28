import Foundation
#if os(Windows)
import CMP3Decoder
#else
import CryptoKit
#endif

public enum PenError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}
public extension Data {
    func u16(_ offset: Int) throws -> UInt16 {
        guard offset >= 0, offset <= count - 2 else { throw PenError.invalid("字段超出文件边界：\(offset)") }
        return UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }
    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= count - 4 else { throw PenError.invalid("字段超出文件边界：\(offset)") }
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[offset + $1]) << ($1 * 8) }
    }
    func utf16String(at offset: Int, maximumBytes: Int) -> String? {
        guard offset >= 0, maximumBytes >= 0, offset <= count else { return nil }
        var end = offset
        let limit = offset + Swift.min(maximumBytes, count - offset)
        while end + 1 < limit, self[end] != 0 || self[end + 1] != 0 { end += 2 }
        return String(data: subdata(in: offset..<end), encoding: .utf16LittleEndian)
    }
    var sha256: String {
#if os(Windows)
        var digest = [UInt8](repeating: 0, count: 32)
        let status = withUnsafeBytes { input in
            digest.withUnsafeMutableBufferPointer { output in
                pen_windows_sha256(input.bindMemory(to: UInt8.self).baseAddress, input.count, output.baseAddress)
            }
        }
        precondition(status == 0, "SHA-256 provider failed (\(status))")
#else
        let digest = SHA256.hash(data: self)
#endif
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
public struct ArtifactReport: Codable, Sendable {
    public let filename: String
    public let bytes: Int
    public let sha256: String
    public let format: String
    public let status: String
    public let details: [String: String]
    public let limitations: [String]
    public func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
public enum Inspector {
    public static func inspect(_ url: URL) throws -> ArtifactReport {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else { throw PenError.invalid("文件为空。") }
        var details: [String: String] = [:]
        var format = "未知格式", status = "尚无可用解析器"
        var limitations = ["文件后缀不能证明设备兼容；尚未进行实机点读验证。"]
        if data.count > 0x610, String(data: data.prefix(20), encoding: .utf16LittleEndian)?.hasPrefix("OID-READER") == true {
            format = "CHOMP / ZC3306B 固件"; status = "已识别封装"
            details["构建标识"] = data.utf16String(at: 0x600, maximumBytes: 0x60)
            details["设备标识"] = String(data: data.prefix(0xa0), encoding: .utf16LittleEndian).map { String($0.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7f }) }
            let address = try data.u32(0xa8)
            if address >= 0x400000 {
                let offset = Int(address - 0x400000) * 2
                if offset <= data.count - 65536 {
                    let allPermutations = (0..<256).allSatisfy { row in Set(data[(offset + row * 256)..<(offset + (row + 1) * 256)]).count == 256 }
                    details["置换表位置"] = String(format: "0x%X", offset)
                    details["256 行置换检查"] = allPermutations ? "每行均包含 0…255" : "未通过"
                }
            }
            if let clips = try? FirmwareAudio.clips(in: data) { details["内置 MP3"] = "\(clips.count) 段，可导出" }
            limitations.append("仅静态读取固件；未反编译或执行，也不会刷写点读笔。")
        } else if url.pathExtension.lowercased() == "bnl", data.count >= 0x200 {
            format = "BNL 候选"; status = "头部指纹已读取"
            let first = try data.u32(0), second = try data.u32(4)
            details["首两字 XOR"] = String(format: "0x%08X", first ^ second)
            details["Albi 头部条件"] = (first ^ second) == 0x200 ? "满足（仍需结构校验）" : "不满足；不可直接套用 Albi 解码"
            let version = data[0x1d0..<0x200].map { ($0 >= 0x20 && $0 < 0x7f) ? $0 : 0x20 }
            details["版本区文本"] = String(bytes: version, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
            if let book = try? BNLBook(data: data, context: .v103) {
                format = "🐛 BNL（模式 2）"
                status = "点读码与媒体目录已验证"
                let mapped = book.routes.filter { $0.index != nil }.count
                let end = Int(try data.u32(0x19c))
                details["明文索引序号数量"] = String(mapped)
                details["索引空槽"] = String(book.routes.count - mapped)
                details["明文索引范围"] = String(format: "0x%X…0x%X", end - book.routes.count * 4, end)
                details["媒体数量"] = String(book.media.count)
            }
            limitations.append("未知变体只展示指纹，不会猜测字段或输出伪造的目标包。")
        } else if url.pathExtension.lowercased() == "bnf" {
            let metadata = try BNFMetadata.read(data)
            format = "BNF（SS_Book_Code）"
            status = "注册码段已读取"
            details["BNF 版本字段"] = String(metadata.version)
            details["包标识原始值"] = metadata.identifierHex
            details["码段标记位置"] = String(format: "0x%X", metadata.markerOffset)
            details["注册码段数量"] = String(metadata.ranges.count)
            for (index, range) in metadata.ranges.enumerated() {
                details["注册码段 \(index + 1)"] = "\(range.start)…\(range.end)（\(range.count) 个值）"
            }
            if let value = metadata.trailingMetadataWord { details["0xEE 原始字段（含义待确认）"] = String(value) }
            do {
                let book = try BNFBook(data: data)
                status = "完整目录已解析，可导出音频与点读命令"
                details["完整目录"] = "已验证"
                details["媒体数量"] = String(book.media.count)
                details["音频点读码"] = String(book.commands.filter { $0.type == 2 && $0.oid != nil }.count)
                details["实际目录码段"] = book.ranges.map { "\($0.start)…\($0.end)" }.joined(separator: "、")
            } catch {
                details["完整目录"] = "未通过"
                details["目录校验结果"] = error.localizedDescription
            }
            limitations.append("目录解析与音频导出不等于跨格式转换完成；纸面点阵和生成包的实机兼容性仍需验证。")
        } else if ["nob", "nod", "nos", "noc"].contains(url.pathExtension.lowercased()) {
            format = "小时候的🐸候选（\(url.pathExtension.uppercased())）"
            if data.prefix(3) == Data("NOD".utf8) {
                do {
                    let book = try NODOpenBook(data: data)
                    format = "小时候的🐸开放 NOD V1（受限格式）"
                    status = "文件结构与校验通过；尚未实机验证"
                    details["书籍编号"] = String(book.bookID)
                    details["正文音频点"] = String(book.routes.count)
                    details["选书点读码"] = book.coverCodes.map(String.init).joined(separator: "、")
                    details["用户标识"] = book.userID
                    details["书籍时间字段"] = book.bookTime
                    limitations.append("仅支持开放 V1、每个码一段主音频的已恢复布局；未验证 A8S 实机兼容。BNF 载荷仍未解码。")
                } catch {
                    status = "未通过受限开放 NOD 解析器"
                    details["解析结果"] = error.localizedDescription
                    limitations.append("不支持的 NOD 变体与损坏文件均不会被当作已验证格式。")
                }
            } else {
                limitations.append("此变体尚无经过样本验证的读写实现。")
            }
        }
        details["头部 32 字节"] = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        return ArtifactReport(filename: url.lastPathComponent, bytes: data.count, sha256: data.sha256, format: format, status: status, details: details, limitations: limitations)
    }
    public static func saveReport(_ report: ArtifactReport, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PenError.invalid("目标已存在，请选择新名称。") }
        try report.json().write(to: url, options: .withoutOverwriting)
    }
}

// Structural observations verified across the 36 supplied files. This is not an audio codec.
public enum BNLEvidence {
    public struct Index: Sendable {
        public let start: Int
        public let end: Int
        public let values: Int
        public let holes: Int
    }
    public static func index(in data: Data) -> Index? {
        guard data.count >= 0x204,
              Array(data[0x1c0..<0x1c9]).map({ $0 ^ 0x80 }) == Array("Chomptech".utf8),
              let endValue = try? data.u32(0x19c) else { return nil }
        let end = Int(endValue)
        guard end > 0x214, end <= Swift.min(data.count, 0x20000), end % 4 == 0 else { return nil }
        let needle = Data([0,0,0,0,1,0,0,0,2,0,0,0,3,0,0,0])
        guard let match = data.range(of: needle, in: 0x204..<end), match.lowerBound % 4 == 0 else { return nil }
        let start = match.lowerBound
        var expected: UInt32 = 0, holes = 0
        for position in stride(from: start, to: end, by: 4) {
            guard let word = try? data.u32(position) else { return nil }
            if word == expected { expected += 1 }
            else if word == UInt32.max { holes += 1 }
            else { return nil }
        }
        guard Int(expected) == (start - 0x204) / 4 else { return nil }
        return Index(start: start, end: end, values: Int(expected), holes: holes)
    }
}
