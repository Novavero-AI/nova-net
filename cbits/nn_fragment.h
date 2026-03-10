/*
 * nn_fragment.h — Message fragmentation and reassembly
 *
 * Splits large messages into MTU-sized fragments with a 6-byte header.
 * Reassembles incoming fragments into complete messages.
 *
 * Fragment header (6 bytes, little-endian):
 *   Bytes 0-3: message_id (uint32_t LE)
 *   Byte 4:    fragment_index
 *   Byte 5:    fragment_count
 *
 * NOTE: gbnet-hs used big-endian for message_id. nova-net standardises
 * all multi-byte wire fields to little-endian.
 */

#ifndef NN_FRAGMENT_H
#define NN_FRAGMENT_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Fragment header size in bytes. */
#define NN_FRAGMENT_HEADER_SIZE 6

/** Maximum fragments per message (uint8_t range). */
#define NN_MAX_FRAGMENT_COUNT 255

/** Minimum safe MTU. */
#define NN_MIN_MTU 576

/** Maximum typical MTU. */
#define NN_MAX_MTU 1500

/* ---------------------------------------------------------------------------
 * Fragment header
 * ------------------------------------------------------------------------- */

typedef struct {
    uint32_t message_id;
    uint8_t  fragment_index;
    uint8_t  fragment_count;
} nn_fragment_header;

/**
 * Write fragment header to buf (exactly NN_FRAGMENT_HEADER_SIZE bytes).
 * Caller must ensure buf has room. Returns NN_FRAGMENT_HEADER_SIZE.
 */
int nn_fragment_write(const nn_fragment_header *hdr, uint8_t *buf);

/**
 * Read fragment header from buf.
 * Returns 0 on success, -1 if buf_len < NN_FRAGMENT_HEADER_SIZE.
 */
int nn_fragment_read(const uint8_t *buf, size_t buf_len,
                     nn_fragment_header *out);

/* ---------------------------------------------------------------------------
 * Fragmentation (split a message)
 * ------------------------------------------------------------------------- */

/**
 * Compute how many fragments a message of `msg_len` bytes needs
 * at the given `max_payload` per fragment.
 *
 * Returns the fragment count, or -1 if it would exceed NN_MAX_FRAGMENT_COUNT.
 */
int nn_fragment_count(size_t msg_len, size_t max_payload);

/**
 * Write one fragment (header + payload slice) into `out_buf`.
 *
 * msg:          full message data
 * msg_len:      full message length
 * message_id:   unique ID for this message
 * frag_index:   which fragment (0-based)
 * frag_count:   total fragment count
 * max_payload:  max payload bytes per fragment
 * out_buf:      output buffer (must have room for header + payload)
 *
 * Returns total bytes written (header + payload), or -1 on error.
 */
int nn_fragment_build(const uint8_t *msg, size_t msg_len,
                      uint32_t message_id, uint8_t frag_index,
                      uint8_t frag_count, size_t max_payload,
                      uint8_t *out_buf);

#endif /* NN_FRAGMENT_H */
