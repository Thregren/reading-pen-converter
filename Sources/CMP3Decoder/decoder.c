#include "PenMP3Decoder.h"
#define MINIMP3_ONLY_MP3
#define MINIMP3_IMPLEMENTATION
#include "vendor/minimp3.h"

/* No resynchronization or undecodable frames are accepted. PCM is decoded into
   a bounded stack buffer and discarded, not merely inferred from frame headers. */
PenMP3ValidationResult pen_mp3_validate(const uint8_t *bytes, size_t length) {
    PenMP3ValidationResult out = {0};
    mp3dec_t decoder;
    mp3d_sample_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
    mp3dec_init(&decoder);
    if (!bytes || !length) { out.error_code = 1; return out; }
    size_t cursor = 0;
    while (cursor < length) {
        out.error_offset = cursor;
        if (length - cursor < 4) { out.error_code = 2; return out; }
        const uint8_t *p = bytes + cursor;
        unsigned h = ((unsigned)p[0] << 24) | ((unsigned)p[1] << 16) | ((unsigned)p[2] << 8) | p[3];
        unsigned version = (h >> 19) & 3, layer = (h >> 17) & 3;
        unsigned bitrate = (h >> 12) & 15, rate = (h >> 10) & 3;
        if ((h >> 21) != 0x7ff || version == 1 || layer != 1 || bitrate == 0 || bitrate == 15 || rate == 3) {
            out.error_code = 2; return out;
        }
        static const unsigned rates[3] = {44100,48000,32000};
        static const unsigned br1[16] = {0,32,40,48,56,64,80,96,112,128,160,192,224,256,320,0};
        static const unsigned br2[16] = {0,8,16,24,32,40,48,56,64,80,96,112,128,144,160,0};
        unsigned expected_channels = ((h >> 6) & 3) == 3 ? 1 : 2;
        unsigned hz = rates[rate] / (version == 3 ? 1 : version == 2 ? 2 : 4);
        unsigned kbps = version == 3 ? br1[bitrate] : br2[bitrate];
        unsigned expected = (version == 3 ? 144 : 72) * kbps * 1000 / hz + ((h >> 9) & 1);
        if (expected > length - cursor) { out.error_code = 2; return out; }
        mp3dec_frame_info_t info = {0};
        size_t remaining = length - cursor;
        int available = (int)(remaining > 65536 ? 65536 : remaining);
        int samples = mp3dec_decode_frame(&decoder, p, available, pcm, &info);
        if (samples != (version == 3 ? 1152 : 576) || info.frame_offset != 0 || info.frame_bytes != (int)expected || info.layer != 3) {
            out.error_code = 3; return out;
        }
        if (info.hz != (int)hz || info.channels != (int)expected_channels ||
            (out.frame_count && (out.sample_rate != (uint32_t)info.hz || out.channels != (uint32_t)info.channels))) {
            out.error_code = 4; return out;
        }
        out.sample_rate = (uint32_t)info.hz;
        out.channels = (uint32_t)info.channels;
        out.sample_frames += (uint64_t)samples;
        out.frame_count++;
        cursor += expected;
    }
    if (out.frame_count < 3 || !out.sample_frames) { out.error_code = 5; return out; }
    out.error_offset = length;
    return out;
}
