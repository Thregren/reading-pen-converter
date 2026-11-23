import Foundation
import CMP3Decoder

/// Validates the entire MPEG frame region using the pinned, embedded minimp3
/// decoder. No system audio service, external executable or network is required.
public enum MP3Decoder {
    public struct Validation: Sendable {
        public let sampleFrames: UInt64
        public let sampleRate: Double
        public let channels: UInt32
    }

    public static func validate(_ data: Data) throws -> Validation {
        guard let bounds = MP3Structure.bounds(data) else { throw PenError.invalid("替换音频的 MP3 帧结构不完整。") }
        let result = data.withUnsafeBytes { buffer in
            pen_mp3_validate(buffer.bindMemory(to: UInt8.self).baseAddress!.advanced(by: bounds.audioStart), bounds.frameEnd - bounds.audioStart)
        }
        guard result.error_code == 0, result.sample_frames > 0, result.frame_count == UInt64(bounds.frames) else {
            throw PenError.invalid("替换 MP3 在字节 \(bounds.audioStart + result.error_offset) 处无法完整解码（错误 \(result.error_code)）。")
        }
        return Validation(sampleFrames: result.sample_frames, sampleRate: Double(result.sample_rate), channels: result.channels)
    }
}
