import Foundation

public struct AudioClip: Codable, Sendable, Identifiable {
    public let index: Int
    public let offset: Int
    public let length: Int
    public var id: Int { index }
}
public struct ExtractionManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let sourceFilename: String
    public let sourceSHA256: String
    public let format: String
    public let clips: [AudioClip]
}
public enum FirmwareAudio {
    public static func clips(in data: Data) throws -> [AudioClip] {
        guard data.count >= 0xb0, String(data: data.prefix(20), encoding: .utf16LittleEndian)?.hasPrefix("OID-READER") == true else {
            throw PenError.invalid("不是受支持的 CHOMP 固件。")
        }
        let address = try data.u32(0xa0)
        guard address >= 0x400000 else { throw PenError.invalid("音频表地址无效。") }
        let base = Int(address - 0x400000) * 2
        let first = Int(try data.u32(base))
        guard first >= 8, first <= 65536, first % 4 == 0, base <= data.count - first else {
            throw PenError.invalid("音频索引长度无效。")
        }
        let offsets = try (0..<(first / 4)).map { Int(try data.u32(base + $0 * 4)) }
        guard offsets.first == first else { throw PenError.invalid("首段音频位置不匹配。") }
        return try offsets.indices.dropLast().map { index in
            let start = base + offsets[index], end = base + offsets[index + 1]
            guard start >= base + first, end > start, end <= data.count else { throw PenError.invalid("音频索引越界或顺序错误。") }
            guard end - start >= 2, (data[start] == 0xff && data[start + 1] & 0xe0 == 0xe0) ||
                    (end - start >= 3 && data[start] == 0x49 && data[start + 1] == 0x44 && data[start + 2] == 0x33) else {
                throw PenError.invalid("第 \(index) 段不是已识别的 MP3，拒绝猜测解码。")
            }
            return AudioClip(index: index, offset: start, length: end - start)
        }
    }
    public static func extract(_ source: URL, to destination: URL) throws -> ExtractionManifest {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let clips = try clips(in: data)
        let manifest = ExtractionManifest(schemaVersion: 1, sourceFilename: source.lastPathComponent, sourceSHA256: data.sha256, format: "CHOMP firmware embedded MP3", clips: clips)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PenError.invalid("输出目录已存在，请选择新名称。") }
        let parent = destination.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".penconvert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for clip in clips {
                let url = staging.appendingPathComponent(String(format: "system_%04d.mp3", clip.index))
                try data.subdata(in: clip.offset..<(clip.offset + clip.length)).write(to: url, options: .withoutOverwriting)
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch { try? FileManager.default.removeItem(at: staging); throw error }
        return manifest
    }
}
