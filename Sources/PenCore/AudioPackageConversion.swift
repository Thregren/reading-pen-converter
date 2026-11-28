import Foundation

public enum AudioPackageConversion {
    public struct Summary: Sendable {
        public let routes: Int
        public let media: Int
        public let omitted: Int
        public let repaired: Int
    }

    public static func targetExtension(for source: URL) throws -> String {
        switch source.pathExtension.lowercased() {
        case "bnl": return "bnf"
        case "bnf": return "bnl"
        default: throw PenError.invalid("请选择 BNF 或 BNL 点读包。")
        }
    }

    public static func batchDestination(for source: URL, in folder: URL) throws -> URL {
        let ext = try targetExtension(for: source)
        let stem = source.deletingPathExtension().lastPathComponent + "-音频版"
        var number = 1
        while true {
            let name = number == 1 ? stem : "\(stem) (\(number))"
            let url = folder.appendingPathComponent(name).appendingPathExtension(ext)
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path),
               !fm.fileExists(atPath: url.appendingPathExtension("conversion.json").path) { return url }
            number += 1
        }
    }

    public static func convert(_ source: URL, template: URL, to destination: URL) throws -> Summary {
        let context = BNLContext.v103
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let templateData = try Data(contentsOf: template, options: .mappedIfSafe)
        if try targetExtension(for: source) == "bnf" {
            let book = try BNLBook(data: data, context: context)
            let result = try BNLToBNFConverter.convert(book, template: templateData, nonAudio: .omitWithReport)
            try ConversionFiles.save(result.data, report: result.report, to: destination)
            return Summary(routes: result.report.mappedRouteCount, media: result.report.mediaCount,
                           omitted: result.report.omittedEventFieldOffsets.count, repaired: result.report.audioRepairs?.count ?? 0)
        }
        let book = try BNFBook(data: data)
        let target = try BNLBook(data: templateData, context: context)
        let result = try BNFToBNLConverter.convert(book, template: target, systemControls: .omitWithReport)
        try ConversionFiles.save(result.data, report: result.report, to: destination, bnlContext: context)
        return Summary(routes: result.report.routeCount, media: result.report.mediaCount,
                       omitted: result.report.omittedSystemControls.count, repaired: 0)
    }
}
