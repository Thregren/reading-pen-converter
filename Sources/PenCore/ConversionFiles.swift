import Foundation

public enum ConversionFiles {
    /// Saves a newly generated package and its scope/validation receipt together.
    /// Existing files are never replaced.
    public static func save<T: Encodable>(_ data: Data, report: T, to destination: URL, bnlContext: BNLContext? = nil) throws {
        let receipt = destination.appendingPathExtension("conversion.json")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path), !fm.fileExists(atPath: receipt.path) else {
            throw PenError.invalid("输出包或转换报告已存在，请选择新的文件名。")
        }
        if destination.pathExtension.lowercased() == "bnf" {
            let candidate = try PackageConflicts.Package(name: destination.lastPathComponent, data: data)
            let siblings = try fm.contentsOfDirectory(at: destination.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey])
                .filter { $0.pathExtension.lowercased() == "bnf" }.sorted { $0.path < $1.path }
            for sibling in siblings {
                let existing: PackageConflicts.Package
                do {
                    guard try sibling.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw PenError.invalid("不是普通文件")
                    }
                    existing = try .init(name: sibling.lastPathComponent, data: Data(contentsOf: sibling))
                } catch {
                    throw PenError.invalid("无法完成同目录 BNF 冲突检查：\(sibling.lastPathComponent)：\(error.localizedDescription)。请使用可完整检查的输出目录。")
                }
                if let conflict = PackageConflicts.detect([existing, candidate]).first {
                    throw PenError.invalid("与同目录的 \(sibling.lastPathComponent) 存在点读码冲突（\(conflict.affectedCodes.start)…\(conflict.affectedCodes.end)），未保存。改文件名不能消除码段冲突。")
                }
            }
        }
        if destination.pathExtension.lowercased() == "bnl" {
            guard let context = bnlContext else { throw PenError.invalid("保存 BNL 需要固件解码参数，以检查同目录码段冲突。") }
            try BNLPackageConflicts.validateCandidate(data: data, context: context, directory: destination.deletingLastPathComponent())
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let receiptData = try encoder.encode(report)
        try data.write(to: destination, options: .withoutOverwriting)
        do { try receiptData.write(to: receipt, options: .withoutOverwriting) }
        catch { try? fm.removeItem(at: destination); throw error }
    }
}
