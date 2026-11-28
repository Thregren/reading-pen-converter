import Foundation

public enum MP3Structure {
    public struct Bounds: Sendable {
        public let frames: Int
        public let audioStart: Int
        public let frameEnd: Int
        public let contentEnd: Int
        public let padding: Int
    }
    static func frameLength(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        let word = (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(data[offset + $1]) }
        guard word >> 21 == 0x7ff else { return nil }
        let version = Int((word >> 19) & 3), layer = (word >> 17) & 3
        let bitrate = Int((word >> 12) & 15), sample = Int((word >> 10) & 3)
        guard version != 1, layer == 1, bitrate > 0, bitrate < 15, sample < 3 else { return nil }
        let rates = version == 3 ? [0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0] : [0,8,16,24,32,40,48,56,64,80,96,112,128,144,160,0]
        let frequency = [44100,48000,32000][sample] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        return (version == 3 ? 144 : 72) * rates[bitrate] * 1000 / frequency + Int((word >> 9) & 1)
    }
    /// Validates trailing tags while preserving their bytes for package writers.
    static func metadataEnd(_ data: Data, after frames: Int) -> Int? {
        var cursor = frames
        func hasID3v1(at offset: Int) -> Bool {
            offset <= data.count - 128 && data[offset..<(offset + 3)].elementsEqual("TAG".utf8)
        }
        let leadingID3 = hasID3v1(at: cursor)
        if leadingID3 { cursor += 128 }
        if cursor <= data.count - 32, data.subdata(in: cursor..<(cursor + 8)) == Data("APETAGEX".utf8) {
            // APEv2 header + items + footer. Tag size includes footer, not header.
            guard let rawSize = try? data.u32(cursor + 12), let rawCount = try? data.u32(cursor + 16) else { return nil }
            let size = Int(rawSize), itemCount = Int(rawCount)
            guard (try? data.u32(cursor + 8)) == 2000, size >= 32, itemCount <= 10000,
                  size <= data.count - cursor - 32, (try? data.u32(cursor + 20)) == 0xa0000000 else { return nil }
            let footer = cursor + size
            guard data.subdata(in: footer..<(footer + 8)) == Data("APETAGEX".utf8),
                  (try? data.u32(footer + 8)) == 2000, (try? data.u32(footer + 12)) == UInt32(size),
                  (try? data.u32(footer + 16)) == UInt32(itemCount), (try? data.u32(footer + 20)) == 0x80000000 else { return nil }
            var itemCursor = cursor + 32
            for _ in 0..<itemCount {
                guard itemCursor <= footer - 8 else { return nil }
                guard let rawLength = try? data.u32(itemCursor) else { return nil }
                let valueLength = Int(rawLength)
                itemCursor += 8
                guard let keyEnd = data[itemCursor..<footer].firstIndex(of: 0), keyEnd > itemCursor,
                      valueLength <= footer - keyEnd - 1 else { return nil }
                itemCursor = keyEnd + 1 + valueLength
            }
            guard itemCursor == footer else { return nil }
            cursor = footer + 32
        }
        if !leadingID3 && hasID3v1(at: cursor) { cursor += 128 }
        return cursor
    }

    static func audioStart(_ data: Data) -> Int? {
        var start = 0
        if data.starts(with: [0x49, 0x44, 0x33]) {
            guard data.count >= 10, [2,3,4].contains(data[3]), data[6..<10].allSatisfy({ $0 & 128 == 0 }) else { return nil }
            start = 10 + data[6..<10].reduce(0) { ($0 << 7) | Int($1) }
            if data[3] == 4 && data[5] & 16 != 0 { start += 10 }
            guard start <= data.count else { return nil }
        }
        return start
    }

    public static func bounds(_ data: Data) -> Bounds? {
        guard let start = audioStart(data) else { return nil }
        var cursor = start, frames = 0
        while let length = frameLength(data, cursor), length <= data.count - cursor {
            cursor += length; frames += 1
        }
        guard frames >= 3 else { return nil }
        let frameEnd = cursor
        guard let metadataEnd = metadataEnd(data, after: cursor) else { return nil }
        cursor = metadataEnd
        // An unexplained nonzero tail must not be silently removed or called valid.
        guard data[cursor...].allSatisfy({ $0 == 0 }) else { return nil }
        return Bounds(frames: frames, audioStart: start, frameEnd: frameEnd, contentEnd: cursor, padding: data.count - cursor)
    }
}
