/*
 * nn_seq.h — Sequence numbers, ring buffers, and ACK bitfield processing
 *
 * Sequence numbers are 16-bit unsigned integers with half-range wraparound
 * comparison. Ring buffers are fixed-size power-of-2 arrays indexed by
 * (sequence & mask) for O(1) insert/lookup/delete.
 */

#ifndef NN_SEQ_H
#define NN_SEQ_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Half the 16-bit sequence space — threshold for wraparound comparison. */
#define NN_SEQ_HALF_RANGE 32768

/** Ring buffer size (must be power of 2). */
#define NN_SEQ_RING_SIZE 256

/** Ring buffer index mask. */
#define NN_SEQ_RING_MASK (NN_SEQ_RING_SIZE - 1)

/** Number of ACK bits in the internal bitfield (64-bit).
 *  On the wire only 32 bits are sent; the upper 32 remain local. */
#define NN_ACK_BITS_WINDOW 64

/** NACKs needed for fast retransmit. */
#define NN_FAST_RETRANSMIT_THRESHOLD 3

/* ---------------------------------------------------------------------------
 * Sequence number comparison (wraparound-safe)
 * ------------------------------------------------------------------------- */

/** Return 1 if s1 > s2 in circular sequence space. */
static inline int nn_seq_gt(uint16_t s1, uint16_t s2) {
    return ((s1 > s2) && (s1 - s2 <= NN_SEQ_HALF_RANGE))
        || ((s1 < s2) && (s2 - s1 >  NN_SEQ_HALF_RANGE));
}

/** Signed distance from s2 to s1, accounting for wraparound. */
static inline int32_t nn_seq_diff(uint16_t s1, uint16_t s2) {
    int32_t diff = (int32_t)s1 - (int32_t)s2;
    if (diff >  (int32_t)NN_SEQ_HALF_RANGE) diff -= 65536;
    if (diff < -(int32_t)NN_SEQ_HALF_RANGE) diff += 65536;
    return diff;
}

/* ---------------------------------------------------------------------------
 * Received buffer — deduplication tracker
 *
 * 256-entry array of uint16_t. Each slot stores the sequence number that
 * hashes to that index. O(1) insert, O(1) lookup. 512 bytes total.
 * ------------------------------------------------------------------------- */

typedef struct {
    uint16_t seqs[NN_SEQ_RING_SIZE];
    uint8_t  occupied[NN_SEQ_RING_SIZE];
    uint16_t highest;
} nn_recv_buf;

/** Initialize all slots to empty. */
void nn_recv_buf_init(nn_recv_buf *buf);

/** Return 1 if sequence was previously received. */
static inline int nn_recv_buf_exists(const nn_recv_buf *buf, uint16_t seq) {
    int idx = seq & NN_SEQ_RING_MASK;
    return buf->occupied[idx] && buf->seqs[idx] == seq;
}

/** Record a received sequence number. */
static inline void nn_recv_buf_insert(nn_recv_buf *buf, uint16_t seq) {
    int idx = seq & NN_SEQ_RING_MASK;
    buf->seqs[idx] = seq;
    buf->occupied[idx] = 1;
    if (nn_seq_gt(seq, buf->highest))
        buf->highest = seq;
}

/* ---------------------------------------------------------------------------
 * Sent packet record — tracked for ACK/NACK and RTT
 * ------------------------------------------------------------------------- */

typedef struct {
    uint8_t  channel_id;
    uint16_t channel_seq;
    uint64_t send_time_ns;   /* monotonic nanoseconds */
    uint32_t size;
    uint8_t  nack_count;
    uint8_t  occupied;       /* 1 = valid entry, 0 = empty slot */
} nn_sent_record;

/* ---------------------------------------------------------------------------
 * Sent packet buffer — ring buffer of sent records
 *
 * 256 entries, indexed by (sequence & 0xFF). O(1) all operations.
 * ------------------------------------------------------------------------- */

typedef struct {
    nn_sent_record entries[NN_SEQ_RING_SIZE];
    uint16_t       seq_nums[NN_SEQ_RING_SIZE]; /* sequence validation */
    int            count;                       /* cached occupied count */
} nn_sent_buf;

/** Initialize sent buffer (all slots empty). */
void nn_sent_buf_init(nn_sent_buf *buf);

/** Insert a sent packet record. Returns evicted count (0 or 1). */
int nn_sent_buf_insert(nn_sent_buf *buf, uint16_t seq,
                       const nn_sent_record *record);

/** Lookup by sequence number. Returns NULL if not found. */
const nn_sent_record *nn_sent_buf_lookup(const nn_sent_buf *buf, uint16_t seq);

/** Mutable lookup by sequence number. Returns NULL if not found.
 *  Used by nn_ack_process to increment nack_count. */
nn_sent_record *nn_sent_buf_lookup_mut(nn_sent_buf *buf, uint16_t seq);

/** Delete by sequence number. Returns 1 if deleted, 0 if not found. */
int nn_sent_buf_delete(nn_sent_buf *buf, uint16_t seq);

/** Return 1 if sequence is currently tracked. */
static inline int nn_sent_buf_exists(const nn_sent_buf *buf, uint16_t seq) {
    int idx = seq & NN_SEQ_RING_MASK;
    return buf->entries[idx].occupied && buf->seq_nums[idx] == seq;
}

/* ---------------------------------------------------------------------------
 * Generic sequence buffer — ring buffer for arbitrary per-sequence data
 *
 * Used for channel message tracking. Stores a validity flag + sequence
 * number per slot. Payload data is managed by the caller alongside.
 * ------------------------------------------------------------------------- */

typedef struct {
    uint16_t seq_nums[NN_SEQ_RING_SIZE];
    uint8_t  occupied[NN_SEQ_RING_SIZE];
    uint16_t highest;
} nn_seq_buf;

/** Initialize sequence buffer (all slots empty). */
void nn_seq_buf_init(nn_seq_buf *buf);

/** Mark a slot as occupied with the given sequence number. */
static inline void nn_seq_buf_insert(nn_seq_buf *buf, uint16_t seq) {
    int idx = seq & NN_SEQ_RING_MASK;
    buf->seq_nums[idx] = seq;
    buf->occupied[idx] = 1;
    if (nn_seq_gt(seq, buf->highest))
        buf->highest = seq;
}

/** Return 1 if the sequence number is present. */
static inline int nn_seq_buf_exists(const nn_seq_buf *buf, uint16_t seq) {
    int idx = seq & NN_SEQ_RING_MASK;
    return buf->occupied[idx] && buf->seq_nums[idx] == seq;
}

/** Clear a slot. */
static inline void nn_seq_buf_delete(nn_seq_buf *buf, uint16_t seq) {
    int idx = seq & NN_SEQ_RING_MASK;
    if (buf->occupied[idx] && buf->seq_nums[idx] == seq)
        buf->occupied[idx] = 0;
}

/* ---------------------------------------------------------------------------
 * ACK bitfield utilities
 * ------------------------------------------------------------------------- */

/**
 * Update remote sequence and ACK bitfield after receiving a packet.
 *
 * remote_seq:  [in/out] current remote sequence (updated if seq is newer)
 * ack_bits:    [in/out] 64-bit ACK bitfield (updated)
 * seq:         the received sequence number
 */
void nn_ack_update(uint16_t *remote_seq, uint64_t *ack_bits, uint16_t seq);

/* ---------------------------------------------------------------------------
 * Loss window — 256-bit rolling tracker (4 x uint64_t)
 * ------------------------------------------------------------------------- */

typedef struct {
    uint64_t bits[4]; /* bits[0]=0-63, bits[1]=64-127, bits[2]=128-191, bits[3]=192-255 */
    uint32_t index;   /* next write position (mod 256) */
    int      count;   /* number of samples recorded (max 256) */
} nn_loss_window;

/** Initialize loss window (all clear = all successful). */
void nn_loss_window_init(nn_loss_window *lw);

/** Record a sample (lost=1, success=0). */
void nn_loss_window_record(nn_loss_window *lw, int lost);

/** Compute loss fraction (0.0 to 1.0). Returns 0.0 if no samples. */
double nn_loss_window_percent(const nn_loss_window *lw);

/* ---------------------------------------------------------------------------
 * LCG + SplitMix output mixing — deterministic, pure, no global state
 *
 * State transition: Knuth MMIX LCG (full 2^64 period).
 * Output function: SplitMix64 bijective mixing for high-quality output.
 * ------------------------------------------------------------------------- */

/** Advance state and return mixed output. */
static inline uint64_t nn_rng_next(uint64_t *state) {
    uint64_t s = *state * 6364136223846793005ull + 1442695040888963407ull;
    *state = s;
    uint64_t z = s ^ (s >> 30);
    z *= 0xBF58476D1CE4E5B9ull;
    z ^= (z >> 27);
    z *= 0x94D049BB133111EBull;
    z ^= (z >> 31);
    return z;
}

/** Convert random uint64 to double in [0, 1) using 53 mantissa bits. */
static inline double nn_rng_double(uint64_t val) {
    return (double)(val >> 11) * (1.0 / 9007199254740992.0); /* 1 / 2^53 */
}

#endif /* NN_SEQ_H */
