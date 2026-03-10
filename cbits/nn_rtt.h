/*
 * nn_rtt.h -- Jacobson/Karels RTT estimation (RFC 6298)
 *
 * Integer-only arithmetic using bit-shifts for the EWMA factors.
 * All state lives in a caller-provided struct -- no heap, no globals.
 * One sample accepted per ACK packet (not averaged across a batch).
 */

#ifndef NN_RTT_H
#define NN_RTT_H

#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** EWMA alpha for SRTT: 1/8, computed as right-shift by 3. */
#define NN_RTT_ALPHA_SHIFT 3

/** EWMA beta for RTTVAR: 1/4, computed as right-shift by 2. */
#define NN_RTT_BETA_SHIFT 2

/** K multiplier for RTTVAR in RTO formula. */
#define NN_RTT_RTO_K 4

/** Minimum RTO in nanoseconds (50 ms). */
#define NN_RTT_RTO_MIN_NS 50000000LL

/** Maximum RTO in nanoseconds (2000 ms). */
#define NN_RTT_RTO_MAX_NS 2000000000LL

/** Clock granularity G in nanoseconds (1 ms). */
#define NN_RTT_GRANULARITY_NS 1000000LL

/** Sentinel: SRTT not yet initialized. */
#define NN_RTT_UNINITIALIZED (-1LL)

/* ---------------------------------------------------------------------------
 * RTT estimator
 * ------------------------------------------------------------------------- */

typedef struct {
    int64_t  srtt_ns;       /* smoothed RTT, -1 = uninitialized */
    int64_t  rttvar_ns;     /* RTT variance */
    int64_t  rto_ns;        /* retransmission timeout */
    uint32_t sample_count;  /* total samples processed */
} nn_rtt;

/** Initialize estimator (uninitialized state, RTO = max). */
void nn_rtt_init(nn_rtt *rtt);

/**
 * Feed one RTT sample (nanoseconds).
 *
 * First sample:  SRTT = sample, RTTVAR = sample/2.
 * Subsequent:    Jacobson/Karels EWMA via integer bit-shifts.
 * RTO is clamped to [NN_RTT_RTO_MIN_NS, NN_RTT_RTO_MAX_NS].
 */
void nn_rtt_update(nn_rtt *rtt, int64_t sample_ns);

/** Current RTO. Returns NN_RTT_RTO_MAX_NS if uninitialized. */
static inline int64_t nn_rtt_rto(const nn_rtt *rtt) {
    return rtt->rto_ns;
}

/** Current SRTT. Returns 0 if uninitialized. */
static inline int64_t nn_rtt_srtt(const nn_rtt *rtt) {
    return (rtt->srtt_ns == NN_RTT_UNINITIALIZED) ? 0 : rtt->srtt_ns;
}

/** Return 1 if at least one sample has been processed. */
static inline int nn_rtt_is_initialized(const nn_rtt *rtt) {
    return rtt->srtt_ns != NN_RTT_UNINITIALIZED;
}

#endif /* NN_RTT_H */
