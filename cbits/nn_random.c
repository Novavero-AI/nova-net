/*
 * nn_random.c — OS CSPRNG wrapper
 *
 * Uses the best available OS primitive on each platform.
 */

#include "nn_random.h"
#include <stdlib.h>

#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
  /* arc4random_buf: always succeeds, no seeding needed */

  void nn_random_bytes(uint8_t *buf, size_t len) {
      arc4random_buf(buf, len);
  }

#elif defined(__linux__)
  /* getentropy: up to NN_GETENTROPY_MAX bytes per call */
  #include <unistd.h>
  #include <sys/random.h>

  #define NN_GETENTROPY_MAX 256

  void nn_random_bytes(uint8_t *buf, size_t len) {
      while (len > 0) {
          size_t chunk = len < NN_GETENTROPY_MAX ? len : NN_GETENTROPY_MAX;
          if (getentropy(buf, chunk) != 0) {
              /* Fatal: OS entropy source failed */
              abort();
          }
          buf += chunk;
          len -= chunk;
      }
  }

#elif defined(_WIN32)
  #include <windows.h>
  #include <bcrypt.h>
  #include <limits.h>

  void nn_random_bytes(uint8_t *buf, size_t len) {
      if (len > (size_t)ULONG_MAX) {
          abort();
      }
      NTSTATUS status = BCryptGenRandom(NULL, buf, (ULONG)len,
                                         BCRYPT_USE_SYSTEM_PREFERRED_RNG);
      if (status != 0) {
          /* Fatal: OS entropy source failed */
          abort();
      }
  }

#else
  #error "Unsupported platform: no CSPRNG available"
#endif
