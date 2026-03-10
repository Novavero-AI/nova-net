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
#include "nn_rtt.h"
#include "nn_ack_process.h"
#include "nn_congestion.h"
#include <string.h>

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

/* ---------------------------------------------------------------------------
 * RTT estimation
 * ------------------------------------------------------------------------- */

size_t nn_ffi_rtt_size(void)
{ return sizeof(nn_rtt); }

void nn_ffi_rtt_init(void *rtt)
{ nn_rtt_init((nn_rtt *)rtt); }

void nn_ffi_rtt_update(void *rtt, int64_t sample_ns)
{ nn_rtt_update((nn_rtt *)rtt, sample_ns); }

int64_t nn_ffi_rtt_rto(const void *rtt)
{ return nn_rtt_rto((const nn_rtt *)rtt); }

int64_t nn_ffi_rtt_srtt(const void *rtt)
{ return nn_rtt_srtt((const nn_rtt *)rtt); }

/* ---------------------------------------------------------------------------
 * Sent buffer
 * ------------------------------------------------------------------------- */

size_t nn_ffi_sent_buf_size(void)
{ return sizeof(nn_sent_buf); }

void nn_ffi_sent_buf_init(void *buf)
{ nn_sent_buf_init((nn_sent_buf *)buf); }

int nn_ffi_sent_buf_insert(void *buf, uint16_t seq,
                            uint8_t channel_id, uint16_t channel_seq,
                            uint64_t send_time_ns, uint32_t size)
{
    nn_sent_record rec;
    memset(&rec, 0, sizeof(rec));
    rec.channel_id   = channel_id;
    rec.channel_seq  = channel_seq;
    rec.send_time_ns = send_time_ns;
    rec.size         = size;
    rec.nack_count   = 0;
    rec.occupied     = 1;
    return nn_sent_buf_insert((nn_sent_buf *)buf, seq, &rec);
}

int nn_ffi_sent_buf_count(const void *buf)
{ return ((const nn_sent_buf *)buf)->count; }

/* ---------------------------------------------------------------------------
 * Loss window
 * ------------------------------------------------------------------------- */

size_t nn_ffi_loss_window_size(void)
{ return sizeof(nn_loss_window); }

void nn_ffi_loss_window_init(void *lw)
{ nn_loss_window_init((nn_loss_window *)lw); }

double nn_ffi_loss_window_percent(const void *lw)
{ return nn_loss_window_percent((const nn_loss_window *)lw); }

/* ---------------------------------------------------------------------------
 * ACK processing
 * ------------------------------------------------------------------------- */

void nn_ffi_ack_process(void *sent_buf, void *loss_window,
                        uint16_t ack_seq, uint32_t ack_bitfield,
                        uint64_t now_ns,
                        int32_t *out_acked_count, int32_t *out_acked_bytes,
                        int64_t *out_rtt_sample_ns,
                        int32_t *out_lost_count,
                        int32_t *out_fast_retransmit,
                        uint16_t *out_retransmit_seq)
{
    nn_ack_result result;
    nn_ack_process((nn_sent_buf *)sent_buf, (nn_loss_window *)loss_window,
                   ack_seq, ack_bitfield, now_ns, &result);
    *out_acked_count     = result.acked_count;
    *out_acked_bytes     = result.acked_bytes;
    *out_rtt_sample_ns   = result.rtt_sample_ns;
    *out_lost_count      = result.lost_count;
    *out_fast_retransmit = result.fast_retransmit;
    *out_retransmit_seq  = result.retransmit_seq;
}

/* ---------------------------------------------------------------------------
 * Congestion: AIMD
 * ------------------------------------------------------------------------- */

size_t nn_ffi_cong_aimd_size(void)
{ return sizeof(nn_cong_aimd); }

void nn_ffi_cong_aimd_init(void *c, double base_rate,
                            double loss_threshold, int64_t rtt_threshold_ns)
{ nn_cong_aimd_init((nn_cong_aimd *)c, base_rate, loss_threshold, rtt_threshold_ns); }

void nn_ffi_cong_aimd_tick(void *c, double dt_sec,
                            double loss_frac, int64_t srtt_ns, int64_t now_ns)
{ nn_cong_aimd_tick((nn_cong_aimd *)c, dt_sec, loss_frac, srtt_ns, now_ns); }

int nn_ffi_cong_aimd_can_send(const void *c)
{ return nn_cong_aimd_can_send((const nn_cong_aimd *)c); }

void nn_ffi_cong_aimd_deduct(void *c)
{ nn_cong_aimd_deduct((nn_cong_aimd *)c); }

double nn_ffi_cong_aimd_rate(const void *c)
{ return nn_cong_aimd_rate((const nn_cong_aimd *)c); }

/* ---------------------------------------------------------------------------
 * Congestion: CWND
 * ------------------------------------------------------------------------- */

size_t nn_ffi_cong_cwnd_size(void)
{ return sizeof(nn_cong_cwnd); }

void nn_ffi_cong_cwnd_init(void *c, uint32_t mss)
{ nn_cong_cwnd_init((nn_cong_cwnd *)c, mss); }

void nn_ffi_cong_cwnd_on_ack(void *c, int32_t acked_bytes)
{ nn_cong_cwnd_on_ack((nn_cong_cwnd *)c, acked_bytes); }

void nn_ffi_cong_cwnd_on_loss(void *c, uint16_t loss_seq, int64_t now_ns)
{ nn_cong_cwnd_on_loss((nn_cong_cwnd *)c, loss_seq, now_ns); }

int nn_ffi_cong_cwnd_can_send(const void *c, int32_t pkt_size)
{ return nn_cong_cwnd_can_send((const nn_cong_cwnd *)c, pkt_size); }

void nn_ffi_cong_cwnd_on_send(void *c, int32_t pkt_size, int64_t now_ns)
{ nn_cong_cwnd_on_send((nn_cong_cwnd *)c, pkt_size, now_ns); }

int64_t nn_ffi_cong_cwnd_pacing_ns(const void *c)
{ return nn_cong_cwnd_pacing_ns((const nn_cong_cwnd *)c); }

void nn_ffi_cong_cwnd_check_idle(void *c, int64_t now_ns, int64_t rto_ns)
{ nn_cong_cwnd_check_idle((nn_cong_cwnd *)c, now_ns, rto_ns); }

void nn_ffi_cong_cwnd_on_ack_seq(void *c, uint16_t acked_seq, int32_t acked_bytes)
{ nn_cong_cwnd_on_ack_seq((nn_cong_cwnd *)c, acked_seq, acked_bytes); }

void nn_ffi_cong_cwnd_set_srtt(void *c, int64_t srtt_ns)
{ ((nn_cong_cwnd *)c)->srtt_ns = srtt_ns; }
