import Foundation

public enum BNFSystemControlPolicy: String, Codable, Sendable {
    case reject
    /// Explicitly omit the verified v11 profile selectors only. Other controls still fail.
    case omitWithReport
}

public struct BNFToBNLReport: Codable, Sendable {
    public struct OmittedControl: Codable, Sendable {
        public let code: UInt32
        public let type: UInt16
        public let reference: UInt32
        public let randomWord: UInt32
        public let trailingWord: UInt16
    }
    public struct NormalizedPlaybackMode: Codable, Sendable {
        public let oid: UInt32
        public let trailingWord: UInt16
    }
    public let normalizedPlaybackModes: [NormalizedPlaybackMode]
    public let sourceSHA256: String
    public let outputSHA256: String
    public let routeCount: Int
    public let mediaCount: Int
    public let originalMediaIndices: [Int]
    public let omittedSystemControls: [OmittedControl]
    public let highFlaggedCommandCount: Int
    public let unreferencedMediaIndices: [Int]
    public let limitations: [String]
}

public struct BNFToBNLResult: Sendable {
    public let data: Data
    public let report: BNFToBNLReport
}

public enum BNFToBNLConverter {
    public static func convert(_ source: BNFBook, template: BNLBook,
                               systemControls: BNFSystemControlPolicy = .reject) throws -> BNFToBNLResult {
        let controls = source.commands.compactMap { command -> BNFToBNLReport.OmittedControl? in
            guard let code = command.oid, !command.isHighFlagged, command.type == 3 || command.type == 30 else { return nil }
            return .init(code: code, type: command.type, reference: command.reference, randomWord: command.randomWord, trailingWord: command.trailingWord)
        }
        // This rejects all unsupported active commands, including recording/game;
        // permitting the verified profile selectors does not broaden the allowed type set.
        let routes = try source.audioRoutes(allowSystemControls: systemControls == .omitWithReport)
        let indices = Set(routes.flatMap(\.mediaIndices)).sorted()
        let mapping = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        var audio: [Data] = []
        for index in indices {
            let bytes = try source.validatedAudio(at: index)
            audio.append(bytes)
        }
        let points = routes.map { route in
            BNLWritePoint(code: route.oid, mediaIDs: route.mediaIndices.map { mapping[$0]! })
        }
        let output = try BNLWriter.write(template: template, points: points, audio: audio)
        let normalized = source.commands.compactMap { command -> BNFToBNLReport.NormalizedPlaybackMode? in
            guard let oid = command.oid, command.type == 2, command.trailingWord != 1 else { return nil }
            return .init(oid: oid, trailingWord: command.trailingWord)
        }
        let report = BNFToBNLReport(normalizedPlaybackModes: normalized, sourceSHA256: source.sourceSHA256, outputSHA256: output.sha256,
            routeCount: routes.count, mediaCount: audio.count, originalMediaIndices: indices,
            omittedSystemControls: controls, highFlaggedCommandCount: source.commands.filter { $0.oid != nil && $0.isHighFlagged }.count,
            unreferencedMediaIndices: source.media.map(\.index).filter { mapping[$0] == nil },
            limitations: BNLWriter.limitations + (normalized.isEmpty ? [] : ["原轮换、随机等播放行为已规范化为固定音频播放列表，非行为无损转换；原点读码与模式值见 normalizedPlaybackModes。"] ) + (controls.isEmpty ? [] : ["已按显式选项省略已验证 v11 单组模板的两个无提示音选择器；原始完整参数见 omittedSystemControls，选择状态行为不保留。" ]))
        return .init(data: output, report: report)
    }
}
