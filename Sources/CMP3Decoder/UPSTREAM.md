# Embedded minimp3 decoder

Upstream: https://github.com/lieff/minimp3

Pinned commit: `a2ad968c94819fb98589cca8026e0a57958c963c`

License: CC0-1.0 Universal, retained verbatim in LICENSE.

Fetched from the official repository on 2026-11-16:

- `vendor/minimp3.h`: https://raw.githubusercontent.com/lieff/minimp3/a2ad968c94819fb98589cca8026e0a57958c963c/minimp3.h
  SHA-256: `af5a24330f4c5029be0f1aa32f3f81f6339bc823df1e2ce1b87292c0b9013286`
- `LICENSE`: https://raw.githubusercontent.com/lieff/minimp3/a2ad968c94819fb98589cca8026e0a57958c963c/LICENSE
  SHA-256: `6a1ee543e5282cd9061881edf462e6fdab181f328da71fc2c9a6950a80e94d01`

Upstream files are unmodified. `decoder.c` and `include/PenMP3Decoder.h` are local wrappers. Only MPEG Layer III is compiled (`MINIMP3_ONLY_MP3`), with no runtime downloads or external binary. The wrapper requires complete sequential frames, exact frame consumption without sync skipping, positive decoded PCM for every frame, consistent sample rate/channels, and complete consumption of the frame region identified independently by Swift. This is decoder acceptance, not a mathematical proof that every possible compressed-bit corruption is detectable or that a pen accepts a rebuilt BNL.
