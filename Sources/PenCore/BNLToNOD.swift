import Foundation

public struct BNLToNODRoute: Codable, Sendable {
    public let code: UInt32
    public let mediaID: Int
    public let audioSHA256: String
    public let isCover: Bool
}

public struct BNLToNODMedia: Codable, Sendable {
    public let id: Int
    public let bytes: Int
    public let sha256: String
    public let mp3Frames: Int
    public let zeroPaddingRemoved: Int
}

public struct BNLToNODResult: Codable, Sendable {
    public let sourceSHA256: String
    public let outputSHA256: String
    public let outputBytes: Int
    public let routes: [BNLToNODRoute]
    public let media: [BNLToNODMedia]
    public let coverCode: UInt32
    public let bookID: UInt32
    public let skippedEmptyRoutes: Int
    public let experimental: Bool
    public let deviceVerified: Bool
    public let limitations: [String]
}

extension BNLBook {
    /// Converts single-track, nonempty registrations without renumbering OIDs.
    /// The selected existing registration becomes the NOD cover registration.
    public func convertToOpenNOD(coverCode: UInt32, bookID: UInt32, to destination: URL) throws -> BNLToNODResult {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw PenError.invalid("输出文件已存在，请选择新名称。")
        }
        let nonempty = routes.filter { !$0.mediaIDs.isEmpty }
        guard let cover = nonempty.first(where: { $0.code == coverCode }), cover.mediaIDs.count == 1 else {
            throw PenError.invalid("封面点读码必须是原 BNL 中已有的非空单音轨点读码。")
        }
        guard nonempty.allSatisfy({ $0.mediaIDs.count == 1 }) else {
            throw PenError.invalid("BNL 含多音轨点读码，当前转换无法完整保留其播放行为。")
        }
        var audio: [Int: Data] = [:]
        var exported: [BNLToNODMedia] = []
        for id in Set(nonempty.map { $0.mediaIDs[0] }).sorted() {
            guard let track = media.first(where: { $0.id == id }) else {
                throw PenError.invalid("点读码引用了不存在的媒体 \(id)。")
            }
            let allocated = try allocatedAudio(track)
            guard let bounds = MP3Structure.bounds(allocated) else {
                throw PenError.invalid("引用的 BNL 媒体 \(id) 不是完整 MP3，无法转换。")
            }
            let clip = Data(allocated.prefix(bounds.contentEnd))
            _ = try MP3Decoder.validate(clip)
            audio[id] = clip
            exported.append(BNLToNODMedia(id: id, bytes: clip.count, sha256: clip.sha256,
                mp3Frames: bounds.frames, zeroPaddingRemoved: bounds.padding))
        }
        // All lookups below are guaranteed by the validated media-ID set above.
        let coverAudio = audio[cover.mediaIDs[0]]!
        let regular = nonempty.filter { $0.code != coverCode }.map { NODRoute(code: $0.code, audio: audio[$0.mediaIDs[0]]!) }
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.calendar = Calendar(identifier: .gregorian)
        date.dateFormat = "yyyyMMddHHmmss"
        let time = date.string(from: Date())
        var random = SystemRandomNumberGenerator()
        let secret = Data((0..<64).map { _ in UInt8.random(in: .min ... .max, using: &random) })
        let parameters = NODOpenParameters(bookID: bookID, userID: "local", bookTime: time, secret64: secret)
        let output = try NODOpenBook.build(routes: regular, coverAudio: coverAudio, coverCodes: [coverCode], parameters: parameters)
        let verified = try NODOpenBook(data: output)
        guard verified.bookID == bookID, verified.userID == "local", verified.bookTime == time, verified.extInfo == parameters.extInfo,
              verified.coverCodes == [coverCode], verified.coverAudio.sha256 == coverAudio.sha256,
              verified.routes.count == regular.count else {
            throw PenError.invalid("NOD 回读后的封面、身份或路由数量不一致。")
        }
        var observed: [UInt32: String] = [:]
        for route in verified.routes {
            guard observed.updateValue(route.audio.sha256, forKey: route.code) == nil else {
                throw PenError.invalid("NOD 回读出现重复点读码。")
            }
        }
        guard observed.updateValue(verified.coverAudio.sha256, forKey: coverCode) == nil else {
            throw PenError.invalid("NOD 封面点读码与普通路由冲突。")
        }
        let hashes = Dictionary(uniqueKeysWithValues: exported.map { ($0.id, $0.sha256) })
        var expected: [UInt32: String] = [:]
        var receipts: [BNLToNODRoute] = []
        for route in nonempty {
            let id = route.mediaIDs[0]
            let hash = hashes[id]!
            guard expected.updateValue(hash, forKey: route.code) == nil else {
                throw PenError.invalid("原 BNL 出现重复点读码。")
            }
            receipts.append(BNLToNODRoute(code: route.code, mediaID: id, audioSHA256: hash, isCover: route.code == coverCode))
        }
        guard observed == expected else { throw PenError.invalid("NOD 回读的逐点读码音频哈希与原 BNL 不一致。") }
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".penconvert-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try output.write(to: staging, options: .withoutOverwriting)
        // Publishing a hard link is atomic and fails if the destination was created
        // concurrently; unlike a rename, it never replaces an existing file.
        try manager.linkItem(at: staging, to: destination)
        return BNLToNODResult(sourceSHA256: sourceSHA256, outputSHA256: output.sha256, outputBytes: output.count,
            routes: receipts, media: exported, coverCode: coverCode, bookID: bookID,
            skippedEmptyRoutes: routes.count - nonempty.count, experimental: true, deviceVerified: false,
            limitations: ["实验性 OPEN NOD 转换，尚未在小时候的🐸 A8S 实机验证。", "保留非空单音轨数值点读码及音频；空槽不生成。", "所选原点读码作为封面；本地身份为 local，不包含原书授权或额外交互行为。"])
    }
}
