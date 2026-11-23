import Foundation

/// Checks the full registered bounds used by v103's active-book cache, including
/// unmapped slots. It does not model physical OID recognition or refresh caches.
public enum BNLPackageConflicts {
    public static func validateCandidate(data: Data, context: BNLContext, directory: URL) throws {
        let candidate = try bounds(data: data, context: context)
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [])
            .filter { $0.pathExtension.lowercased() == "bnl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let existing: ClosedRange<UInt32>
            do {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw PenError.invalid("不是普通文件。")
                }
                existing = try bounds(data: Data(contentsOf: file), context: context)
            } catch {
                throw PenError.invalid("无法检查同目录 BNL「\(file.lastPathComponent)」：\(error.localizedDescription)")
            }
            let low = max(candidate.lowerBound, existing.lowerBound)
            let high = min(candidate.upperBound, existing.upperBound)
            guard low > high else {
                throw PenError.invalid("与同目录 BNL「\(file.lastPathComponent)」的注册范围 \(existing.lowerBound)…\(existing.upperBound) 冲突：重叠点读码 \(low)…\(high)（包括空槽）。请使用不含冲突点读包的目录。")
            }
        }
    }

    private static func bounds(data: Data, context: BNLContext) throws -> ClosedRange<UInt32> {
        let book = try BNLBook(data: data, context: context)
        // BNLBook preserves every slot between header194 and198, even index=nil.
        guard let first = book.routes.first, let last = book.routes.last else {
            throw PenError.invalid("BNL 没有可验证的注册范围。")
        }
        // This variant has an optional additional range sector. The current
        // parser covers only the primary pair; never silently ignore extension ranges.
        guard try data.u32(0x1a0) == UInt32.max else {
            throw PenError.invalid("BNL 含尚未支持的扩展注册范围，无法排除冲突。")
        }
        return first.code...last.code
    }
}
