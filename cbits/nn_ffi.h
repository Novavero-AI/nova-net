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

/* ---------------------------------------------------------------------------
 * Recv buffer
 * ------------------------------------------------------------------------- */

/** Size of nn_recv_buf struct. */
size_t nn_ffi_recv_buf_size(void);

/** Init recv buffer. */
void nn_ffi_recv_buf_init(void *buf);

/** Return 1 if sequence was previously received. */
int nn_ffi_recv_buf_exists(const void *buf, uint16_t seq);

/** Record a received sequence number. */
void nn_ffi_recv_buf_insert(void *buf, uint16_t seq);

/** Highest received sequence number. */
uint16_t nn_ffi_recv_buf_highest(const void *buf);

/* ---------------------------------------------------------------------------
 * RTT estimation
 * ------------------------------------------------------------------------- */

/** Size of nn_rtt struct. */
size_t nn_ffi_rtt_size(void);

/** Init RTT estimator. */
void nn_ffi_rtt_init(void *rtt);

/** Feed one RTT sample (nanoseconds). */
void nn_ffi_rtt_update(void *rtt, int64_t sample_ns);

/** Get current RTO (nanoseconds). */
int64_t nn_ffi_rtt_rto(const void *rtt);

/** Get current SRTT (nanoseconds). */
int64_t nn_ffi_rtt_srtt(const void *rtt);

/* ---------------------------------------------------------------------------
 * Sent buffer (opaque)
 * ------------------------------------------------------------------------- */

/** Size of nn_sent_buf struct. */
size_t nn_ffi_sent_buf_size(void);

/** Init sent buffer. */
void nn_ffi_sent_buf_init(void *buf);

/** Insert a record. Returns 0 or 1 (eviction). */
int nn_ffi_sent_buf_insert(void *buf, uint16_t seq,
                            uint8_t channel_id, uint16_t channel_seq,
                            uint64_t send_time_ns, uint32_t size);

/** Current count of occupied entries. */
int nn_ffi_sent_buf_count(const void *buf);

/* ---------------------------------------------------------------------------
 * Loss window (opaque)
 * ------------------------------------------------------------------------- */

/** Size of nn_loss_window struct. */
size_t nn_ffi_loss_window_size(void);

/** Init loss window. */
void nn_ffi_loss_window_init(void *lw);

/** Get loss percentage (0.0 to 1.0). */
double nn_ffi_loss_window_percent(const void *lw);

/* ---------------------------------------------------------------------------
 * ACK processing
 * ------------------------------------------------------------------------- */

/** Process ACK bitfield against sent buffer. */
void nn_ffi_ack_process(void *sent_buf, void *loss_window,
                        uint16_t ack_seq, uint32_t ack_bitfield,
                        uint64_t now_ns,
                        int32_t *out_acked_count, int32_t *out_acked_bytes,
                        int64_t *out_rtt_sample_ns,
                        int32_t *out_lost_count,
                        int32_t *out_fast_retransmit,
                        uint16_t *out_retransmit_seq);

/* ---------------------------------------------------------------------------
 * Congestion: AIMD
 * ------------------------------------------------------------------------- */

/** Size of nn_cong_aimd struct. */
size_t nn_ffi_cong_aimd_size(void);

/** Init AIMD controller. */
void nn_ffi_cong_aimd_init(void *c, double base_rate,
                            double loss_threshold, int64_t rtt_threshold_ns);

/** Per-tick update. */
void nn_ffi_cong_aimd_tick(void *c, double dt_sec,
                            double loss_frac, int64_t srtt_ns, int64_t now_ns);

/** Returns 1 if budget >= 1.0. */
int nn_ffi_cong_aimd_can_send(const void *c);

/** Deduct one packet from budget. */
void nn_ffi_cong_aimd_deduct(void *c);

/** Current send rate. */
double nn_ffi_cong_aimd_rate(const void *c);

/* ---------------------------------------------------------------------------
 * Congestion: CWND
 * ------------------------------------------------------------------------- */

/** Size of nn_cong_cwnd struct. */
size_t nn_ffi_cong_cwnd_size(void);

/** Init CWND controller. */
void nn_ffi_cong_cwnd_init(void *c, uint32_t mss);

/** Process acked bytes (grow window). */
void nn_ffi_cong_cwnd_on_ack(void *c, int32_t acked_bytes);

/** Process loss event. */
void nn_ffi_cong_cwnd_on_loss(void *c, uint16_t loss_seq, int64_t now_ns);

/** Returns 1 if in_flight + pkt_size <= cwnd. */
int nn_ffi_cong_cwnd_can_send(const void *c, int32_t pkt_size);

/** Record a sent packet. */
void nn_ffi_cong_cwnd_on_send(void *c, int32_t pkt_size, int64_t now_ns);

/** Pacing interval (nanoseconds). 0 = no pacing. */
int64_t nn_ffi_cong_cwnd_pacing_ns(const void *c);

/** Check for idle restart. */
void nn_ffi_cong_cwnd_check_idle(void *c, int64_t now_ns, int64_t rto_ns);

/** Process acked seq (in_flight tracking + recovery exit). */
void nn_ffi_cong_cwnd_on_ack_seq(void *c, uint16_t acked_seq, int32_t acked_bytes);

/** Update cached SRTT for pacing. */
void nn_ffi_cong_cwnd_set_srtt(void *c, int64_t srtt_ns);

#endif /* NN_FFI_H */
