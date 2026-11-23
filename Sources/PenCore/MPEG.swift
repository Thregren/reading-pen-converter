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
    public static func bounds(_ data: Data) -> Bounds? {
        var start = 0
        if data.starts(with: [0x49, 0x44, 0x33]) {
            guard data.count >= 10, [2,3,4].contains(data[3]), data[6..<10].allSatisfy({ $0 & 128 == 0 }) else { return nil }
            start = 10 + data[6..<10].reduce(0) { ($0 << 7) | Int($1) }
            if data[3] == 4 && data[5] & 16 != 0 { start += 10 }
            guard start <= data.count else { return nil }
        }
        var cursor = start, frames = 0
        while let length = frameLength(data, cursor), length <= data.count - cursor {
            cursor += length; frames += 1
        }
        guard frames >= 3 else { return nil }
        let frameEnd = cursor
        if cursor <= data.count - 128, data[cursor..<(cursor + 3)].elementsEqual([0x54, 0x41, 0x47]) { cursor += 128 }
        // An unexplained nonzero tail must not be silently removed or called valid.
        guard data[cursor...].allSatisfy({ $0 == 0 }) else { return nil }
        return Bounds(frames: frames, audioStart: start, frameEnd: frameEnd, contentEnd: cursor, padding: data.count - cursor)
    }
}
