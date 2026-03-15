/*
 * nn_siphash.c — SipHash-2-4 reference implementation
 *
 * Adapted from the public-domain reference code by
 * Jean-Philippe Aumasson & Daniel J. Bernstein.
 */

#include "nn_siphash.h"
#include <string.h>

/* ---------------------------------------------------------------------------
 * Internal helpers
 * ------------------------------------------------------------------------- */

static inline uint64_t nn_rotl64(uint64_t x, int b) {
    return (x << b) | (x >> (64 - b));
}

static inline uint64_t nn_load_u64le(const uint8_t *p) {
    uint64_t val;
    memcpy(&val, p, sizeof(val));
    /* On big-endian this would need a swap; SipHash spec uses LE loads.
     * We rely on the same byte-order detection as nn_wire.h. */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    val = ((val >> 56) & 0x00000000000000FFull)
        | ((val >> 40) & 0x000000000000FF00ull)
        | ((val >> 24) & 0x0000000000FF0000ull)
        | ((val >>  8) & 0x00000000FF000000ull)
        | ((val <<  8) & 0x000000FF00000000ull)
        | ((val << 24) & 0x0000FF0000000000ull)
        | ((val << 40) & 0x00FF000000000000ull)
        | ((val << 56) & 0xFF00000000000000ull);
#endif
    return val;
}

#define NN_SIPROUND                         \
    do {                                    \
        v0 += v1; v1 = nn_rotl64(v1, 13);  \
        v1 ^= v0; v0 = nn_rotl64(v0, 32);  \
        v2 += v3; v3 = nn_rotl64(v3, 16);  \
        v3 ^= v2;                           \
        v0 += v3; v3 = nn_rotl64(v3, 21);  \
        v3 ^= v0;                           \
        v2 += v1; v1 = nn_rotl64(v1, 17);  \
        v1 ^= v2; v2 = nn_rotl64(v2, 32);  \
    } while (0)

/* ---------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------- */

uint64_t nn_siphash_2_4(const uint8_t *key, const uint8_t *msg, size_t msg_len) {
    uint64_t k0 = nn_load_u64le(key);
    uint64_t k1 = nn_load_u64le(key + 8);

    uint64_t v0 = k0 ^ UINT64_C(0x736f6d6570736575);
    uint64_t v1 = k1 ^ UINT64_C(0x646f72616e646f6d);
    uint64_t v2 = k0 ^ UINT64_C(0x6c7967656e657261);
    uint64_t v3 = k1 ^ UINT64_C(0x7465646279746573);

    const uint8_t *end = msg + msg_len - (msg_len % 8);
    const size_t left = msg_len & 7;
    uint64_t m;

    /* Process 8-byte blocks */
    for (; msg != end; msg += 8) {
        m = nn_load_u64le(msg);
        v3 ^= m;
        NN_SIPROUND;
        NN_SIPROUND;
        v0 ^= m;
    }

    /* Process remaining bytes + length tag */
    m = (uint64_t)(msg_len & 0xFF) << 56;
    switch (left) {
        case 7: m |= (uint64_t)msg[6] << 48; /* fallthrough */
        case 6: m |= (uint64_t)msg[5] << 40; /* fallthrough */
        case 5: m |= (uint64_t)msg[4] << 32; /* fallthrough */
        case 4: m |= (uint64_t)msg[3] << 24; /* fallthrough */
        case 3: m |= (uint64_t)msg[2] << 16; /* fallthrough */
        case 2: m |= (uint64_t)msg[1] <<  8; /* fallthrough */
        case 1: m |= (uint64_t)msg[0];        break;
        case 0: break;
    }

    v3 ^= m;
    NN_SIPROUND;
    NN_SIPROUND;
    v0 ^= m;

    /* Finalization */
    v2 ^= 0xFF;
    NN_SIPROUND;
    NN_SIPROUND;
    NN_SIPROUND;
    NN_SIPROUND;

    return v0 ^ v1 ^ v2 ^ v3;
}
