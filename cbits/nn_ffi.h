/*
 * nn_ffi.h — Flat FFI entry points for Haskell
 *
 * These functions take scalar arguments instead of struct pointers,
 * avoiding the Storable marshalling overhead on the Haskell side.
 * Each is a thin wrapper around the internal C API.
 */

#ifndef NN_FFI_H
#define NN_FFI_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Packet header
 * ------------------------------------------------------------------------- */

/** Write packet header. Returns bytes written (always 9). */
int nn_ffi_packet_write(uint8_t packet_type, uint16_t seq,
                        uint16_t ack, uint32_t ack_bitfield,
                        uint8_t *buf);

/**
 * Read packet header. Writes fields to out pointers.
 * Returns 0 on success, -1 on error.
 */
int nn_ffi_packet_read(const uint8_t *buf, size_t buf_len,
                       uint8_t *out_type, uint16_t *out_seq,
                       uint16_t *out_ack, uint32_t *out_abf);

/* ---------------------------------------------------------------------------
 * CRC32C
 * ------------------------------------------------------------------------- */

/** Compute CRC32C. */
uint32_t nn_ffi_crc32c(const uint8_t *buf, size_t len);

/** Append CRC32C to buf. Returns new total length. */
size_t nn_ffi_crc32c_append(uint8_t *buf, size_t data_len);

/** Validate CRC32C. Returns payload length, or 0 on failure. */
size_t nn_ffi_crc32c_validate(const uint8_t *buf, size_t total_len);

/* ---------------------------------------------------------------------------
 * Sequence numbers
 * ------------------------------------------------------------------------- */

/** Wraparound-safe greater-than. */
int nn_ffi_seq_gt(uint16_t s1, uint16_t s2);

/** Signed difference with wraparound. */
int32_t nn_ffi_seq_diff(uint16_t s1, uint16_t s2);

/* ---------------------------------------------------------------------------
 * Fragment header
 * ------------------------------------------------------------------------- */

/** Write fragment header. Returns bytes written (always 6). */
int nn_ffi_fragment_write(uint32_t message_id, uint8_t frag_index,
                          uint8_t frag_count, uint8_t *buf);

/** Read fragment header. Returns 0 on success, -1 on error. */
int nn_ffi_fragment_read(const uint8_t *buf, size_t buf_len,
                         uint32_t *out_msg_id, uint8_t *out_index,
                         uint8_t *out_count);

/** Compute fragment count. Returns -1 if too many. */
int nn_ffi_fragment_count(size_t msg_len, size_t max_payload);

/** Build one fragment (header + payload). Returns bytes written or -1. */
int nn_ffi_fragment_build(const uint8_t *msg, size_t msg_len,
                          uint32_t message_id, uint8_t frag_index,
                          uint8_t frag_count, size_t max_payload,
                          uint8_t *out_buf);

/* ---------------------------------------------------------------------------
 * Crypto
 * ------------------------------------------------------------------------- */

/** Encrypt in place. Returns total output length or negative error. */
int nn_ffi_encrypt(const uint8_t *key, uint64_t counter,
                   uint32_t protocol_id,
                   uint8_t *buf, size_t plain_len);

/** Decrypt in place. Returns 0 on success or negative error. */
int nn_ffi_decrypt(const uint8_t *key, uint32_t protocol_id,
                   uint8_t *buf, size_t total_len,
                   uint64_t *out_counter, size_t *out_plain_len);

/* ---------------------------------------------------------------------------
 * Bandwidth
 * ------------------------------------------------------------------------- */

/** Size of nn_bandwidth struct (for Haskell ForeignPtr allocation). */
size_t nn_ffi_bandwidth_size(void);

/** Init bandwidth tracker. */
void nn_ffi_bandwidth_init(void *bw, double window_ms);

/** Record bytes. */
void nn_ffi_bandwidth_record(void *bw, uint32_t size, uint64_t now_ns);

/** Get bytes/sec. */
double nn_ffi_bandwidth_bps(const void *bw, uint64_t now_ns);

#endif /* NN_FFI_H */
