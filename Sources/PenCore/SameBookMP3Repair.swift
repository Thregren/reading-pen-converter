import Foundation

/// Uses complete, decoder-validated recordings of the current book as the only donors.
enum SameBookMP3Repair {
    struct Donor {
        let id: Int
        let data: Data
        let bounds: MP3Structure.Bounds
    }

    struct Result {
        let audio: Data
        let report: BNLToBNFReport.AudioRepair
    }

    static func recover(_ allocation: Data, mediaID: Int, codes: [UInt32], donors: [Donor]) throws -> Result {
        let references = codes.isEmpty ? "本书没有引用它的点读码" : "点读码 " + codes.map(String.init).joined(separator: "、")
        func failure(_ reason: String) -> PenError {
            .invalid("BNL 媒体 \(mediaID) 的录音不完整（\(references)）。\(reason)")
        }
        guard let last = allocation.lastIndex(where: { $0 != 0 }) else {
            throw failure("录音为空，无法在同书中匹配。")
        }
        var start = 0
        if allocation.starts(with: "ID3".utf8) {
            guard let audioStart = MP3Structure.audioStart(allocation), audioStart > 0,
                  audioStart <= last, MP3Structure.frameLength(allocation, audioStart) != nil else {
                throw failure("无法确定录音标签之后的 MP3 帧起点。")
            }
            start = audioStart
        }
        let fragment = allocation.subdata(in: start..<(last + 1))
        guard fragment.count >= 32, Set(fragment.prefix(4096)).count >= 4 else {
            throw failure("有效内容不足，无法在同书中可靠匹配。")
        }
        var recovered: Result?
        for donor in donors {
            var search = donor.bounds.audioStart..<donor.bounds.frameEnd
            guard fragment.count <= search.count else { continue }
            while let match = donor.data.range(of: fragment, in: search) {
                guard let result = recoverMatch(donor, match: match, tagged: start > 0, mediaID: mediaID, codes: codes) else {
                    throw failure("同书中找到了相同字节，但无法确定可独立播放的完整片段。")
                }
                if let previous = recovered {
                    guard previous.audio == result.audio else {
                        throw failure("同书中有多个匹配位置，恢复出的音频不同，无法确定原录音。")
                    }
                } else {
                    recovered = result
                }
                search = (match.lowerBound + 1)..<donor.bounds.frameEnd
                if fragment.count > search.count { break }
            }
        }
        guard let recovered else { throw failure("在同书的完整录音中找不到匹配片段。") }
        return recovered
    }

    private static func recoverMatch(_ donor: Donor, match: Range<Int>, tagged: Bool, mediaID: Int, codes: [UInt32]) -> Result? {
        var boundaries = [donor.bounds.audioStart]
        while let offset = boundaries.last, offset < donor.bounds.frameEnd {
            guard let size = MP3Structure.frameLength(donor.data, offset) else { return nil }
            boundaries.append(offset + size)
        }
        // The original sub-frame edit times are unknown. Use the next frame boundary
        // at each edge and require at least three whole frames inside the match.
        guard let first = boundaries.firstIndex(where: { $0 >= match.lowerBound }),
              let end = boundaries.firstIndex(where: { $0 >= match.upperBound }),
              !tagged || boundaries[first] == match.lowerBound,
              end - first - (boundaries[end] == match.upperBound ? 0 : 1) >= 3 else { return nil }
        let original = donor.data.subdata(in: boundaries[first]..<boundaries[end])
        let result: Data
        let method: String
        if (try? MP3Decoder.validate(original)) != nil {
            result = original
            method = "copy-complete-mpeg-frames"
        } else {
            guard let rebuilt = rebuildFrames(donor.data, boundaries: boundaries, selected: first..<end),
                  (try? MP3Decoder.validate(rebuilt)) != nil else { return nil }
            result = rebuilt
            method = "repack-mpeg-layer3-reservoir"
        }
        return Result(audio: result, report: .init(mediaID: mediaID, donorMediaID: donor.id, pointCodes: codes,
            matchedByteStart: match.lowerBound, matchedByteEnd: match.upperBound,
            firstFrame: first, endFrame: end, method: method))
    }

    /// Layer III's main_data_begin points backwards in a stream formed by joining the
    /// payloads of successive frames, excluding headers, CRC and side information.
    /// Repack the original scalefactor/Huffman bits into independently decodable
    /// frames. Quantized audio, granule side information and frame count are preserved.
    private static func rebuildFrames(_ source: Data, boundaries: [Int], selected: Range<Int>) -> Data? {
        var reservoir = Data()
        var output = Data()
        for index in 0..<selected.upperBound {
            let start = boundaries[index], stop = boundaries[index + 1]
            var header = source.subdata(in: start..<(start + 4))
            let mpeg1 = (header[1] >> 3) & 3 == 3
            let channels = header[3] >> 6 == 3 ? 1 : 2
            let sideCount = mpeg1 ? (channels == 1 ? 17 : 32) : (channels == 1 ? 9 : 17)
            let sideStart = start + 4 + (header[1] & 1 == 0 ? 2 : 0)
            let payloadStart = sideStart + sideCount
            guard payloadStart <= stop else { return nil }
            let payloadOffset = reservoir.count
            reservoir.append(contentsOf: source[payloadStart..<stop])
            guard selected.contains(index) else { continue }
            var side = source.subdata(in: sideStart..<payloadStart)
            let back = mpeg1 ? Int(side[0]) * 2 + Int(side[1] >> 7) : Int(side[0])
            var bit = mpeg1 ? 9 + (channels == 1 ? 5 : 3) + 4 * channels : 8 + channels
            var mainBits = 0
            for _ in 0..<(channels * (mpeg1 ? 2 : 1)) {
                var partLength = 0
                for i in bit..<(bit + 12) {
                    partLength = partLength * 2 + Int((side[i / 8] >> (7 - i % 8)) & 1)
                }
                mainBits += partLength
                bit += mpeg1 ? 59 : 63
            }
            let mainBytes = (mainBits + 7) / 8
            let mainStart = payloadOffset - back
            guard mainStart >= 0, mainStart + mainBytes <= reservoir.count else { return nil }
            side[0] = 0
            if mpeg1 { side[1] &= 0x7f }
            // Removing the optional CRC is signalled by the protection bit.
            header[1] |= 1
            let minimumSize = 4 + sideCount + mainBytes
            var frameSize: Int?
            // Keep original bitrate where possible. Grow only frames borrowing more
            // bits than their nominal size. Layer III permits per-frame bitrate.
            for bitrate in Int(header[2] >> 4)...14 {
                header[2] = UInt8(bitrate << 4) | (header[2] & 0xf)
                if let size = MP3Structure.frameLength(header, 0), size >= minimumSize {
                    frameSize = size
                    break
                }
            }
            guard let frameSize else { return nil }
            output.append(header)
            output.append(side)
            output.append(contentsOf: reservoir[mainStart..<(mainStart + mainBytes)])
            output.append(Data(repeating: 0, count: frameSize - minimumSize))
        }
        return output
    }
}
