import Foundation
import PenCore

func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else {
        print("用法：penconvert inspect <文件>\n      penconvert scan <目录>\n      penconvert audit-bnf <目录>\n      penconvert extract-firmware <固件> <新目录>\n      penconvert convert-bnf-to-bnl <BNF> <The-Journey原始BNL模板> <新BNL> --audio-only\n      penconvert convert-bnl-to-bnf <BNL> <已验证v11单组BNF模板> <新BNF> --audio-only\n      penconvert extract-bnf <BNF文件> <新目录>\n      penconvert extract-bnl <BNL文件> <新目录>\n      penconvert rebuild-bnl <模板BNL> <解码目录> <新BNL文件>\n      penconvert convert-bnl-to-nod <BNL> <封面点读码十进制> <本地bookID十进制> <新NOD>\ninspect、scan、rebuild-bnl、convert-bnl-to-nod 输出 JSON；extract 输出结果摘要。不修改输入文件。")
        exit(1)
    }
    // Retain the explicit firmware argument accepted by previous CLI versions.
    let legacyFirmwareIndex: Int?
    switch (args[0], args.count) {
    case ("convert-bnl-to-bnf", 6), ("convert-bnf-to-bnl", 6):
        legacyFirmwareIndex = 3
    case ("extract-bnl", 4), ("rebuild-bnl", 5), ("convert-bnl-to-nod", 6):
        legacyFirmwareIndex = 2
    default:
        legacyFirmwareIndex = nil
    }
    let context: BNLContext
    if let legacyFirmwareIndex {
        let firmware = URL(fileURLWithPath: args.remove(at: legacyFirmwareIndex))
        context = try BNLContext(firmware: Data(contentsOf: firmware, options: .mappedIfSafe))
    } else {
        context = .v103
    }
    let url = URL(fileURLWithPath: args[1])
    if args[0] == "inspect" {
        print(String(decoding: try Inspector.inspect(url).json(), as: UTF8.self))
    } else if args[0] == "extract-firmware", args.count == 3 {
        let result = try FirmwareAudio.extract(url, to: URL(fileURLWithPath: args[2]))
        print("已导出 \(result.clips.count) 段 MP3。")
    } else if args[0] == "convert-bnl-to-bnf", args.count == 5, args[4] == "--audio-only" {
        let source = try BNLBook(data: Data(contentsOf: url, options: .mappedIfSafe), context: context)
        let template = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
        let result = try BNLToBNFConverter.convert(source, template: template, nonAudio: .omitWithReport)
        try ConversionFiles.save(result.data, report: result.report, to: URL(fileURLWithPath: args[3]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result.report), as: UTF8.self))
    } else if args[0] == "convert-bnf-to-bnl", args.count == 5, args[4] == "--audio-only" {
        let template = try BNLBook(data: Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe), context: context)
        let book = try BNFBook(data: Data(contentsOf: url, options: .mappedIfSafe))
        let result = try BNFToBNLConverter.convert(book, template: template, systemControls: .omitWithReport)
        let destination = URL(fileURLWithPath: args[3])
        try ConversionFiles.save(result.data, report: result.report, to: destination, bnlContext: context)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result.report), as: UTF8.self))
    } else if args[0] == "extract-bnf", args.count == 3 {
        let book = try BNFBook(data: Data(contentsOf: url, options: .mappedIfSafe))
        let result = try book.extract(sourceFilename: url.lastPathComponent, to: URL(fileURLWithPath: args[2]))
        let mp3 = result.media.filter { $0.mp3Frames != nil }.count
        print("已导出 \(mp3) 段 MP3、\(result.media.count - mp3) 段原始媒体，以及完整点读命令表。")
    } else if args[0] == "extract-bnl", args.count == 3 {
        let book = try BNLBook(data: Data(contentsOf: url, options: .mappedIfSafe), context: context)
        let result = try book.extract(sourceFilename: url.lastPathComponent, to: URL(fileURLWithPath: args[2]))
        print("已导出 \(result.media.filter { $0.mp3Frames != nil }.count) 段 MP3、\(result.media.filter { $0.mp3Frames == nil }.count) 段未识别媒体，以及 \(result.routes.count) 个注册映射槽。")
    } else if args[0] == "rebuild-bnl", args.count == 4 {
        let book = try BNLBook(data: Data(contentsOf: url, options: .mappedIfSafe), context: context)
        let result = try book.rebuild(decodedDirectory: URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[3]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    } else if args[0] == "convert-bnl-to-nod", args.count == 5 {
        guard !args[2].isEmpty, args[2].utf8.allSatisfy({ (48...57).contains($0) }), let coverCode = UInt32(args[2]),
              !args[3].isEmpty, args[3].utf8.allSatisfy({ (48...57).contains($0) }), let bookID = UInt32(args[3]) else {
            throw PenError.invalid("封面点读码和本地 bookID 必须是 UInt32 范围内的十进制整数。")
        }
        let book = try BNLBook(data: Data(contentsOf: url, options: .mappedIfSafe), context: context)
        let result = try book.convertToOpenNOD(coverCode: coverCode, bookID: bookID, to: URL(fileURLWithPath: args[4]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    } else if args[0] == "audit-bnf", args.count == 2 {
        struct Failure: Codable { let path: String; let reason: String }
        struct Report: Codable {
            let evidenceScope: String
            let complete: Bool
            let packages: [PackageConflicts.Package]
            let conflicts: [PackageConflicts.Conflict]
            let failures: [Failure]
        }
        var failures: [Failure] = [], packages: [PackageConflicts.Package] = []
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw PenError.invalid("audit-bnf 需要目录路径。")
        }
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { path, error in
            failures.append(Failure(path: path.path, reason: error.localizedDescription)); return true
        }) else { throw PenError.invalid("无法递归读取审计目录。") }
        var files: [URL] = []
        for case let path as URL in entries {
            do {
                let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    failures.append(Failure(path: path.path, reason: "未跟随符号链接；目标未纳入审计。"))
                } else if path.pathExtension.lowercased() == "bnf" {
                    if values.isRegularFile == true { files.append(path) }
                    else { failures.append(Failure(path: path.path, reason: "BNF 路径不是普通文件。")) }
                }
            } catch { failures.append(Failure(path: path.path, reason: error.localizedDescription)) }
        }
        for path in files.sorted(by: { $0.path < $1.path }) {
            do { packages.append(try PackageConflicts.Package(name: path.path, data: Data(contentsOf: path, options: .mappedIfSafe))) }
            catch { failures.append(Failure(path: path.path, reason: error.localizedDescription)) }
        }
        let report = Report(evidenceScope: PackageConflicts.evidenceScope + " 首匹配模型按报告 packages 顺序；不代表设备实际目录排序。", complete: failures.isEmpty,
                            packages: packages, conflicts: PackageConflicts.detect(packages), failures: failures)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    } else if args[0] == "scan" {
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { throw PenError.invalid("无法读取目录") }
        var reports: [ArtifactReport] = []
        for case let path as URL in files where ["bnl", "bnf", "bin", "chp", "nob", "nod", "nos", "noc"].contains(path.pathExtension.lowercased()) {
            reports.append(try Inspector.inspect(path))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(reports), as: UTF8.self))
    } else { throw PenError.invalid("未知命令：\(args[0])") }
}
do { try run() } catch {
    FileHandle.standardError.write(Data("错误：\(error.localizedDescription)\n".utf8)); exit(1)
}
