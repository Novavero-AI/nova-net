/*
 * nn_ffi.c — Flat FFI entry points for Haskell
 *
 * Thin wrappers that take scalar arguments instead of struct pointers.
 */

#include "nn_ffi.h"
#include "nn_packet.h"
#include "nn_crc32c.h"
#include "nn_seq.h"
#include "nn_fragment.h"
#include "nn_crypto.h"
#include "nn_bandwidth.h"

/* ---------------------------------------------------------------------------
 * Packet header
 * ------------------------------------------------------------------------- */

int
nn_ffi_packet_write(uint8_t packet_type, uint16_t seq,
                    uint16_t ack, uint32_t ack_bitfield,
                    uint8_t *buf)
{
    nn_packet_header hdr = {
        .packet_type  = packet_type,
        .sequence_num = seq,
        .ack          = ack,
        .ack_bitfield = ack_bitfield
    };
    return nn_packet_write(&hdr, buf);
}

int
nn_ffi_packet_read(const uint8_t *buf, size_t buf_len,
                   uint8_t *out_type, uint16_t *out_seq,
                   uint16_t *out_ack, uint32_t *out_abf)
{
    nn_packet_header hdr;
    int rc = nn_packet_read(buf, buf_len, &hdr);
    if (rc != 0) return rc;
    *out_type = hdr.packet_type;
    *out_seq  = hdr.sequence_num;
    *out_ack  = hdr.ack;
    *out_abf  = hdr.ack_bitfield;
    return 0;
}

/* ---------------------------------------------------------------------------
 * CRC32C
 * ------------------------------------------------------------------------- */

uint32_t nn_ffi_crc32c(const uint8_t *buf, size_t len)
{ return nn_crc32c(buf, len); }

size_t nn_ffi_crc32c_append(uint8_t *buf, size_t data_len)
{ return nn_crc32c_append(buf, data_len); }

size_t nn_ffi_crc32c_validate(const uint8_t *buf, size_t total_len)
{ return nn_crc32c_validate(buf, total_len); }

/* ---------------------------------------------------------------------------
 * Sequence numbers
 * ------------------------------------------------------------------------- */

int nn_ffi_seq_gt(uint16_t s1, uint16_t s2)
{ return nn_seq_gt(s1, s2); }

int32_t nn_ffi_seq_diff(uint16_t s1, uint16_t s2)
{ return nn_seq_diff(s1, s2); }

/* ---------------------------------------------------------------------------
 * Fragment header
 * ------------------------------------------------------------------------- */

int
nn_ffi_fragment_write(uint32_t message_id, uint8_t frag_index,
                      uint8_t frag_count, uint8_t *buf)
{
    nn_fragment_header hdr = {
        .message_id     = message_id,
        .fragment_index = frag_index,
        .fragment_count = frag_count
    };
    return nn_fragment_write(&hdr, buf);
}

int
nn_ffi_fragment_read(const uint8_t *buf, size_t buf_len,
                     uint32_t *out_msg_id, uint8_t *out_index,
                     uint8_t *out_count)
{
    nn_fragment_header hdr;
    int rc = nn_fragment_read(buf, buf_len, &hdr);
    if (rc != 0) return rc;
    *out_msg_id = hdr.message_id;
    *out_index  = hdr.fragment_index;
    *out_count  = hdr.fragment_count;
    return 0;
}

int nn_ffi_fragment_count(size_t msg_len, size_t max_payload)
{ return nn_fragment_count(msg_len, max_payload); }

int
nn_ffi_fragment_build(const uint8_t *msg, size_t msg_len,
                      uint32_t message_id, uint8_t frag_index,
                      uint8_t frag_count, size_t max_payload,
                      uint8_t *out_buf)
{
    return nn_fragment_build(msg, msg_len, message_id,
                             frag_index, frag_count, max_payload, out_buf);
}

/* ---------------------------------------------------------------------------
 * Crypto
 * ------------------------------------------------------------------------- */

int
nn_ffi_encrypt(const uint8_t *key, uint64_t counter,
               uint32_t protocol_id,
               uint8_t *buf, size_t plain_len)
{ return nn_crypto_encrypt(key, counter, protocol_id, buf, plain_len); }

int
nn_ffi_decrypt(const uint8_t *key, uint32_t protocol_id,
               uint8_t *buf, size_t total_len,
               uint64_t *out_counter, size_t *out_plain_len)
{ return nn_crypto_decrypt(key, protocol_id, buf, total_len, out_counter, out_plain_len); }

/* ---------------------------------------------------------------------------
 * Bandwidth
 * ------------------------------------------------------------------------- */

size_t nn_ffi_bandwidth_size(void)
{ return sizeof(nn_bandwidth); }

void nn_ffi_bandwidth_init(void *bw, double window_ms)
{ nn_bandwidth_init((nn_bandwidth *)bw, window_ms); }

void nn_ffi_bandwidth_record(void *bw, uint32_t size, uint64_t now_ns)
{ nn_bandwidth_record((nn_bandwidth *)bw, size, now_ns); }

double nn_ffi_bandwidth_bps(const void *bw, uint64_t now_ns)
{ return nn_bandwidth_bps((const nn_bandwidth *)bw, now_ns); }
