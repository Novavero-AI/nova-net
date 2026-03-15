/*
 * nn_siphash.h — SipHash-2-4 keyed PRF
 *
 * 128-bit key, 64-bit output. Used for HMAC-bound challenge cookies
 * during handshake. Not on the hot path — handshake only.
 *
 * Reference: Jean-Philippe Aumasson & Daniel J. Bernstein,
 *            "SipHash: a fast short-input PRF" (2012)
 */

#ifndef NN_SIPHASH_H
#define NN_SIPHASH_H

#include <stddef.h>
#include <stdint.h>

/**
 * Compute SipHash-2-4.
 *
 * key:     16-byte key
 * msg:     message bytes
 * msg_len: message length
 *
 * Returns 64-bit hash.
 */
uint64_t nn_siphash_2_4(const uint8_t *key, const uint8_t *msg, size_t msg_len);

#endif /* NN_SIPHASH_H */
