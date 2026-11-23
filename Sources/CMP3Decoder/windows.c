#include "PenWindows.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <bcrypt.h>
#include <limits.h>

int32_t pen_windows_sha256(const uint8_t *bytes, size_t length, uint8_t digest[32]) {
    BCRYPT_ALG_HANDLE algorithm;
    NTSTATUS status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0);
    if (status < 0) {
        return status;
    }

    BCRYPT_HASH_HANDLE hash;
    status = BCryptCreateHash(algorithm, &hash, NULL, 0, NULL, 0, 0);
    if (status >= 0) {
        while (length != 0 && status >= 0) {
            // CNG uses a 32-bit length for each update.
            ULONG count = length > ULONG_MAX ? ULONG_MAX : (ULONG)length;
            status = BCryptHashData(hash, (PUCHAR)bytes, count, 0);
            bytes += count;
            length -= count;
        }
        if (status >= 0) {
            status = BCryptFinishHash(hash, digest, 32, 0);
        }
        BCryptDestroyHash(hash);
    }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return status;
}
#endif
