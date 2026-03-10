/*
 * nn_wire.h — Little-endian wire helpers and buffer utilities
 *
 * All multi-byte fields on the wire are little-endian.
 * On LE platforms (x86, ARM): these compile to plain loads/stores.
 * On BE platforms: single bswap instruction per operation.
 */

#ifndef NN_WIRE_H
#define NN_WIRE_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * Byte order detection
 * ------------------------------------------------------------------------- */

#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
  #define NN_BIG_ENDIAN 1
#else
  #define NN_BIG_ENDIAN 0
#endif

/* ---------------------------------------------------------------------------
 * Byte swap primitives
 * ------------------------------------------------------------------------- */

static inline uint16_t nn_bswap16(uint16_t x) {
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_bswap16(x);
#else
    return (uint16_t)((x >> 8) | (x << 8));
#endif
}

static inline uint32_t nn_bswap32(uint32_t x) {
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_bswap32(x);
#else
    return ((x >> 24) & 0x000000FFu)
         | ((x >>  8) & 0x0000FF00u)
         | ((x <<  8) & 0x00FF0000u)
         | ((x << 24) & 0xFF000000u);
#endif
}

static inline uint64_t nn_bswap64(uint64_t x) {
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_bswap64(x);
#else
    return ((x >> 56) & 0x00000000000000FFull)
         | ((x >> 40) & 0x000000000000FF00ull)
         | ((x >> 24) & 0x0000000000FF0000ull)
         | ((x >>  8) & 0x00000000FF000000ull)
         | ((x <<  8) & 0x000000FF00000000ull)
         | ((x << 24) & 0x0000FF0000000000ull)
         | ((x << 40) & 0x00FF000000000000ull)
         | ((x << 56) & 0xFF00000000000000ull);
#endif
}

/* ---------------------------------------------------------------------------
 * Little-endian write (host → wire)
 *
 * memcpy avoids undefined behaviour from unaligned access.
 * On LE with optimisation the compiler elides the swap and often
 * folds memcpy into a single store instruction.
 * ------------------------------------------------------------------------- */

static inline void nn_write_u8(uint8_t *buf, uint8_t val) {
    buf[0] = val;
}

static inline void nn_write_u16le(uint8_t *buf, uint16_t val) {
#if NN_BIG_ENDIAN
    val = nn_bswap16(val);
#endif
    memcpy(buf, &val, sizeof(val));
}

static inline void nn_write_u32le(uint8_t *buf, uint32_t val) {
#if NN_BIG_ENDIAN
    val = nn_bswap32(val);
#endif
    memcpy(buf, &val, sizeof(val));
}

static inline void nn_write_u64le(uint8_t *buf, uint64_t val) {
#if NN_BIG_ENDIAN
    val = nn_bswap64(val);
#endif
    memcpy(buf, &val, sizeof(val));
}

static inline void nn_write_f32le(uint8_t *buf, float val) {
    uint32_t bits;
    memcpy(&bits, &val, sizeof(bits));
    nn_write_u32le(buf, bits);
}

static inline void nn_write_f64le(uint8_t *buf, double val) {
    uint64_t bits;
    memcpy(&bits, &val, sizeof(bits));
    nn_write_u64le(buf, bits);
}

/* ---------------------------------------------------------------------------
 * Little-endian read (wire → host)
 * ------------------------------------------------------------------------- */

static inline uint8_t nn_read_u8(const uint8_t *buf) {
    return buf[0];
}

static inline uint16_t nn_read_u16le(const uint8_t *buf) {
    uint16_t val;
    memcpy(&val, buf, sizeof(val));
#if NN_BIG_ENDIAN
    val = nn_bswap16(val);
#endif
    return val;
}

static inline uint32_t nn_read_u32le(const uint8_t *buf) {
    uint32_t val;
    memcpy(&val, buf, sizeof(val));
#if NN_BIG_ENDIAN
    val = nn_bswap32(val);
#endif
    return val;
}

static inline uint64_t nn_read_u64le(const uint8_t *buf) {
    uint64_t val;
    memcpy(&val, buf, sizeof(val));
#if NN_BIG_ENDIAN
    val = nn_bswap64(val);
#endif
    return val;
}

static inline float nn_read_f32le(const uint8_t *buf) {
    uint32_t bits = nn_read_u32le(buf);
    float val;
    memcpy(&val, &bits, sizeof(val));
    return val;
}

static inline double nn_read_f64le(const uint8_t *buf) {
    uint64_t bits = nn_read_u64le(buf);
    double val;
    memcpy(&val, &bits, sizeof(val));
    return val;
}

/* ---------------------------------------------------------------------------
 * Buffer bounds checking
 * ------------------------------------------------------------------------- */

/** Return 1 if buf has at least `need` bytes remaining from `offset`. */
static inline int nn_buf_has(size_t buf_len, size_t offset, size_t need) {
    return offset + need <= buf_len && offset + need >= offset;
}

#endif /* NN_WIRE_H */
