/*
 * nn_crc32c.h — CRC32C (Castagnoli) with hardware acceleration
 *
 * SSE4.2 on x86_64, ARMv8 CRC on aarch64, software fallback otherwise.
 * All functions are reentrant and thread-safe.
 */

#ifndef NN_CRC32C_H
#define NN_CRC32C_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Size of a CRC32C checksum in bytes. */
#define NN_CRC32C_SIZE 4

/* ---------------------------------------------------------------------------
 * Core API
 * ------------------------------------------------------------------------- */

/** Compute CRC32C over buf[0..len). */
uint32_t nn_crc32c(const uint8_t *buf, size_t len);

/**
 * Append CRC32C checksum (4 bytes, little-endian) to buf.
 *
 * Caller must ensure buf has room for data_len + NN_CRC32C_SIZE bytes.
 * Returns new total length (data_len + NN_CRC32C_SIZE).
 */
size_t nn_crc32c_append(uint8_t *buf, size_t data_len);

/**
 * Validate CRC32C and return payload length.
 *
 * Returns payload length (total_len - 4) on success, or 0 if the buffer
 * is too short or the checksum does not match.
 */
size_t nn_crc32c_validate(const uint8_t *buf, size_t total_len);

#endif /* NN_CRC32C_H */
