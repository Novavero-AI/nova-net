/*
 * nn_random.h — OS CSPRNG
 *
 * Fills buffers with cryptographically secure random bytes.
 * Uses arc4random_buf (macOS/BSD), getentropy (Linux),
 * or BCryptGenRandom (Windows).
 *
 * Setup/teardown only — not on the hot path.
 */

#ifndef NN_RANDOM_H
#define NN_RANDOM_H

#include <stddef.h>
#include <stdint.h>

/**
 * Fill buf with len cryptographically secure random bytes.
 * Always succeeds (aborts on OS-level failure, which is fatal anyway).
 */
void nn_random_bytes(uint8_t *buf, size_t len);

#endif /* NN_RANDOM_H */
