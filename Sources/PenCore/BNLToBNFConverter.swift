import Foundation

public enum BNLNonAudioPolicy: String, Sendable, Codable {
    case reject
    /// Only numerical audio routes are translated; opaque event fields are listed.
    case omitWithReport
}
public struct BNLToBNFReport: Sendable, Codable {
    public struct OmittedEvent: Sendable, Codable {
        public let fieldOffset: Int
        public let words: [UInt16]
    }
    public let sourceSHA256: String
    public let outputSHA256: String
    public let templateSHA256: String
    public let mediaCount: Int
    public let mappedRouteCount: Int
    public let emptySlotCount: Int
    public let omittedEventFieldOffsets: [Int]
    public let omittedEvents: [OmittedEvent]
    public let limitations: [String]
}
public struct BNLToBNFResult: Sendable {
    public let data: Data
    public let report: BNLToBNFReport
}
public enum BNLToBNFConverter {
    public static func convert(_ source: BNLBook, template: Data,
                               nonAudio: BNLNonAudioPolicy = .reject) throws -> BNLToBNFResult {
        let opaqueEvents = try BNLWriter.eventFields.compactMap { offset -> BNLToBNFReport.OmittedEvent? in
            let raw = try source.data.u32(offset)
            guard raw != 0 && raw != UInt32.max else { return nil }
            let pointer = Int(BNLBook.decodePointer(raw, source.pointerKeys.0, source.pointerKeys.1))
            guard pointer >= 512, pointer <= source.mediaTable - 2 else {
                throw PenError.invalid("BNL 事件表越界，无法确定转换范围。")
            }
            let count = Int(try source.data.u16(pointer))
            guard count <= (source.mediaTable - pointer - 2) / 2 else {
                throw PenError.invalid("BNL 事件表长度越界。")
            }
            guard count > 0 else { return nil }
            return .init(fieldOffset: offset, words: try (0..<count).map { try source.data.u16(pointer + 2 + $0 * 2) })
        }
        guard opaqueEvents.isEmpty || nonAudio == .omitWithReport else {
            throw PenError.invalid("BNL 含有尚未转换的事件字段；需明确选择仅转换音频点读并在报告中列出省略项。")
        }
        let tracks = source.media.sorted { $0.id < $1.id }
        let ids = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($0.element.id, $0.offset) })
        let audio = try tracks.map { track -> Data in
            let allocated = try source.allocatedAudio(track)
            guard let bounds = MP3Structure.bounds(allocated), allocated.dropFirst(bounds.contentEnd).allSatisfy({ $0 == 0 }) else {
                throw PenError.invalid("BNL 媒体 \(track.id) 不是完整 MP3 或具有未识别尾部。")
            }
            let bytes = Data(allocated.prefix(bounds.contentEnd)); _ = try MP3Decoder.validate(bytes); return bytes
        }
        let points = source.routes.map { route in
            BNLWritePoint(code: route.code, mediaIDs: route.mediaIDs.map { ids[$0]! })
        }
        let result = try BNFWriter.write(template: template, points: points, audio: audio)
        return .init(data: result, report: .init(sourceSHA256: source.sourceSHA256, outputSHA256: result.sha256,
            templateSHA256: template.sha256, mediaCount: tracks.count,
            mappedRouteCount: source.routes.filter { $0.index != nil }.count,
            emptySlotCount: source.routes.filter { $0.index == nil }.count,
            omittedEventFieldOffsets: opaqueEvents.map(\.fieldOffset), omittedEvents: opaqueEvents,
            limitations: BNFWriter.limitations + (opaqueEvents.isEmpty ? [] : ["仅转换音频点读映射；原 BNL 的事件及其他非音频行为未移植，省略字段偏移见报告。"])))
    }
}
