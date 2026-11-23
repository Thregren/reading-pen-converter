#ifndef PEN_WINDOWS_H
#define PEN_WINDOWS_H

#ifdef _WIN32
#include <stddef.h>
#include <stdint.h>

/* Returns a CNG status code. Zero means the digest was written. */
int32_t pen_windows_sha256(const uint8_t *bytes, size_t length, uint8_t digest[32]);
#endif

#endif
