/*
 * nn_crypto.h — ChaCha20-Poly1305 AEAD encryption (RFC 8439)
 *
 * Self-contained implementation with no external dependencies.
 * All operations work on caller-provided buffers — no heap allocation.
 *
 * Wire format for encrypted payloads:
 *   [nonce_counter:8 LE][ciphertext:N][auth_tag:16]
 *
 * Nonce construction (12 bytes for ChaCha20):
 *   [counter:8 LE][protocol_id:4 LE]
 *
 * NOTE: gbnet-hs used big-endian for nonce/protocol_id on wire.
 * nova-net standardises everything to little-endian.
 */

#ifndef NN_CRYPTO_H
#define NN_CRYPTO_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Encryption key size in bytes (256-bit). */
#define NN_CRYPTO_KEY_SIZE      32

/** Nonce counter on wire in bytes. */
#define NN_CRYPTO_NONCE_SIZE     8

/** Poly1305 authentication tag size. */
#define NN_CRYPTO_TAG_SIZE      16

/** Total encryption overhead: nonce (8) + tag (16) = 24 bytes. */
#define NN_CRYPTO_OVERHEAD      (NN_CRYPTO_NONCE_SIZE + NN_CRYPTO_TAG_SIZE)

/** ChaCha20 internal nonce size (counter:8 + protocol_id:4). */
#define NN_CHACHA20_NONCE_SIZE  12

/** ChaCha20 block size in bytes. */
#define NN_CHACHA20_BLOCK_SIZE  64

/** Poly1305 block size in bytes. */
#define NN_POLY1305_BLOCK_SIZE  16

/** Mask to round down to Poly1305 block alignment. */
#define NN_POLY1305_BLOCK_MASK  (~(size_t)(NN_POLY1305_BLOCK_SIZE - 1))

/* ---------------------------------------------------------------------------
 * Error codes
 * ------------------------------------------------------------------------- */

#define NN_CRYPTO_OK          0
#define NN_CRYPTO_ERR_KEY    -1   /* invalid key */
#define NN_CRYPTO_ERR_AUTH   -2   /* authentication failed */
#define NN_CRYPTO_ERR_SHORT  -3   /* input too short */

/* ---------------------------------------------------------------------------
 * API
 * ------------------------------------------------------------------------- */

/**
 * Encrypt plaintext in place and prepend nonce + append auth tag.
 *
 * Input layout:   buf contains plaintext at buf[NN_CRYPTO_NONCE_SIZE].
 * Output layout:  [nonce:8 LE][ciphertext:N][auth_tag:16]
 *
 * Simpler API: caller provides the full buffer. On entry:
 *   - buf[0..8)           reserved for nonce (will be written)
 *   - buf[8..8+plain_len) plaintext (will be encrypted in place)
 *   - buf must have room for 8 + plain_len + 16 bytes total
 *
 * key:          32-byte encryption key
 * counter:      monotonic nonce counter
 * protocol_id:  protocol identifier (part of nonce construction)
 * buf:          buffer as described above
 * plain_len:    plaintext length (not including nonce/tag)
 *
 * Returns total output length (nonce + ciphertext + tag) on success,
 * or a negative error code.
 */
int nn_crypto_encrypt(const uint8_t *key, uint64_t counter,
                      uint32_t protocol_id,
                      uint8_t *buf, size_t plain_len);

/**
 * Decrypt ciphertext in place.
 *
 * Input layout:  [nonce:8 LE][ciphertext:N][auth_tag:16]
 * Output layout: plaintext overwrites ciphertext region.
 *
 * key:          32-byte encryption key
 * protocol_id:  protocol identifier
 * buf:          buffer containing encrypted data
 * total_len:    total length including nonce + ciphertext + tag
 * out_counter:  [out] nonce counter extracted from the packet
 * out_plain_len:[out] plaintext length
 *
 * Returns 0 on success, negative error code on failure.
 * On success, plaintext is at buf[NN_CRYPTO_NONCE_SIZE] with
 * length *out_plain_len.
 */
int nn_crypto_decrypt(const uint8_t *key, uint32_t protocol_id,
                      uint8_t *buf, size_t total_len,
                      uint64_t *out_counter, size_t *out_plain_len);

#endif /* NN_CRYPTO_H */
