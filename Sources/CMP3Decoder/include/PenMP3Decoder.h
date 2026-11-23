#ifndef PEN_MP3_DECODER_H
#define PEN_MP3_DECODER_H
#include <stddef.h>
#include <stdint.h>
typedef struct {
    uint64_t sample_frames;
    uint64_t frame_count;
    uint32_t sample_rate;
    uint32_t channels;
    size_t error_offset;
    int error_code;
} PenMP3ValidationResult;
/* Input is only the complete MPEG frame region: no ID3 or allocation padding. */
PenMP3ValidationResult pen_mp3_validate(const uint8_t *bytes, size_t length);
#endif
