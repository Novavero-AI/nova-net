/*
 * nn_packet.h — Wire packet header serialization
 *
 * 68-bit header: 4-bit type + 16-bit sequence + 16-bit ack + 32-bit ack bitfield.
 * Packed into 9 bytes with 4 bits of padding.
 *
 * Wire layout (MSB-first within each byte):
 *   Byte 0:     [type:4][seq_hi:4]
 *   Byte 1:     [seq_mid:8]
 *   Byte 2:     [seq_lo:4][ack_hi:4]
 *   Byte 3:     [ack_mid:8]
 *   Byte 4:     [ack_lo:4][abf_hi:4]
 *   Bytes 5-7:  [abf:24]
 *   Byte 8:     [abf_lo:4][pad:4]
 */

#ifndef NN_PACKET_H
#define NN_PACKET_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Header size in bits (4 + 16 + 16 + 32). */
#define NN_PACKET_HEADER_BIT_SIZE  68

/** Header size in bytes (9). */
#define NN_PACKET_HEADER_SIZE      9

/** Number of packet types (fits in 4 bits). */
#define NN_PACKET_TYPE_COUNT       8

/** Maximum valid packet type value. */
#define NN_PACKET_TYPE_MAX         7

/* ---------------------------------------------------------------------------
 * Packet types (4 bits on wire)
 * ------------------------------------------------------------------------- */

#define NN_PKT_CONNECTION_REQUEST   0
#define NN_PKT_CONNECTION_ACCEPTED  1
#define NN_PKT_CONNECTION_DENIED    2
#define NN_PKT_PAYLOAD              3
#define NN_PKT_DISCONNECT           4
#define NN_PKT_KEEPALIVE            5
#define NN_PKT_CONNECTION_CHALLENGE 6
#define NN_PKT_CONNECTION_RESPONSE  7

/* ---------------------------------------------------------------------------
 * Packet header struct
 * ------------------------------------------------------------------------- */

typedef struct {
    uint8_t  packet_type;   /* 4 bits on wire (0-7) */
    uint16_t sequence_num;  /* 16 bits */
    uint16_t ack;           /* 16 bits — most recent received sequence */
    uint32_t ack_bitfield;  /* 32 bits — preceding 32 acks */
} nn_packet_header;

/* ---------------------------------------------------------------------------
 * Serialization
 * ------------------------------------------------------------------------- */

/**
 * Write a packet header to buf (exactly NN_PACKET_HEADER_SIZE bytes).
 *
 * Caller must ensure buf has at least NN_PACKET_HEADER_SIZE bytes.
 * Returns number of bytes written (always NN_PACKET_HEADER_SIZE).
 */
int nn_packet_write(const nn_packet_header *hdr, uint8_t *buf);

/**
 * Read a packet header from buf.
 *
 * Returns 0 on success, -1 if buf_len < NN_PACKET_HEADER_SIZE or
 * packet type is invalid.
 */
int nn_packet_read(const uint8_t *buf, size_t buf_len, nn_packet_header *out);

#endif /* NN_PACKET_H */
