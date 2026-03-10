/*
 * nn_congestion.h -- Dual-layer congestion control
 *
 * Layer 1: Binary AIMD — additive increase, multiplicative decrease.
 *          Simple Good/Bad mode with adaptive recovery time.
 *
 * Layer 2: TCP-like CWND — slow start, congestion avoidance, recovery.
 *          Byte-based window with pacing and idle restart (RFC 2861).
 *
 * Both layers operate on caller-provided structs.  No heap, no globals.
 * The Haskell protocol brain selects which layer to use via config.
 */

#ifndef NN_CONGESTION_H
#define NN_CONGESTION_H

#include "nn_seq.h"
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * AIMD constants
 * ------------------------------------------------------------------------- */

/** Additive increase: +1.0 packet/sec per tick in Good mode. */
#define NN_CONG_AIMD_INCREASE 1.0

/** Multiplicative decrease factor on entering Bad mode. */
#define NN_CONG_AIMD_DECREASE 0.5

/** Maximum send rate = base_rate * this multiplier. */
#define NN_CONG_AIMD_MAX_MULTIPLIER 4.0

/** Minimum send rate in packets/sec. */
#define NN_CONG_AIMD_MIN_RATE 1.0

/** Minimum recovery time (1 second in nanoseconds). */
#define NN_CONG_RECOVERY_MIN_NS 1000000000LL

/** Maximum recovery time (60 seconds in nanoseconds). */
#define NN_CONG_RECOVERY_MAX_NS 60000000000LL

/** Double recovery time if re-entering Bad within this window (5 seconds). */
#define NN_CONG_RECOVERY_DOUBLE_NS 5000000000LL

/** Halve recovery time after sustained Good for this duration (10 seconds). */
#define NN_CONG_RECOVERY_HALVE_NS 10000000000LL

/* ---------------------------------------------------------------------------
 * CWND constants
 * ------------------------------------------------------------------------- */

/** Initial congestion window in MSS units (RFC 6928). */
#define NN_CWND_INITIAL_MSS 10

/** Minimum congestion window in MSS units. */
#define NN_CWND_MIN_MSS 2

/** Default slow-start threshold (64 KB). */
#define NN_CWND_SSTHRESH_DEFAULT 65536.0

/** Number of RTOs of inactivity before idle restart (RFC 2861). */
#define NN_CWND_IDLE_RTOS 2

/* ---------------------------------------------------------------------------
 * AIMD types
 * ------------------------------------------------------------------------- */

typedef enum {
    NN_CONG_GOOD = 0,
    NN_CONG_BAD  = 1
} nn_cong_mode;

typedef struct {
    nn_cong_mode mode;
    double       send_rate;         /* packets/sec */
    double       base_rate;         /* baseline rate */
    double       budget;            /* available send budget (fractional) */
    double       loss_threshold;    /* loss fraction that triggers Bad */
    int64_t      rtt_threshold_ns;  /* RTT that triggers Bad */
    int64_t      recovery_time_ns;  /* current recovery duration (adaptive) */
    int64_t      recovery_start_ns; /* timestamp Bad mode entered, 0 = N/A */
    int64_t      last_good_ns;      /* timestamp of last sustained Good tick */
} nn_cong_aimd;

/* ---------------------------------------------------------------------------
 * CWND types
 * ------------------------------------------------------------------------- */

typedef enum {
    NN_CWND_SLOW_START = 0,
    NN_CWND_AVOIDANCE  = 1,
    NN_CWND_RECOVERY   = 2
} nn_cwnd_phase;

typedef struct {
    nn_cwnd_phase phase;
    double        cwnd;             /* window in bytes */
    double        ssthresh;         /* slow-start threshold in bytes */
    uint32_t      mss;              /* max segment size (bytes) */
    int32_t       in_flight;        /* bytes in flight */
    uint16_t      recovery_seq;     /* seq when recovery entered */
    int64_t       last_send_ns;     /* timestamp of last send */
    int64_t       last_activity_ns; /* for idle restart */
    int64_t       srtt_ns;          /* cached SRTT for pacing */
} nn_cong_cwnd;

/* ---------------------------------------------------------------------------
 * AIMD API
 * ------------------------------------------------------------------------- */

/** Initialize AIMD controller. */
void nn_cong_aimd_init(nn_cong_aimd *c, double base_rate,
                       double loss_threshold, int64_t rtt_threshold_ns);

/**
 * Per-tick update.  Transitions modes, adjusts send_rate, refills budget.
 *
 * dt_sec:     seconds since last tick
 * loss_frac:  current loss fraction (0.0 to 1.0)
 * srtt_ns:    current smoothed RTT in nanoseconds
 * now_ns:     current monotonic time
 */
void nn_cong_aimd_tick(nn_cong_aimd *c, double dt_sec,
                       double loss_frac, int64_t srtt_ns, int64_t now_ns);

/** Can we send a packet? (budget >= 1.0) */
static inline int nn_cong_aimd_can_send(const nn_cong_aimd *c) {
    return c->budget >= 1.0;
}

/** Deduct one packet from budget. */
static inline void nn_cong_aimd_deduct(nn_cong_aimd *c) {
    c->budget -= 1.0;
}

/** Current send rate in packets/sec. */
static inline double nn_cong_aimd_rate(const nn_cong_aimd *c) {
    return c->send_rate;
}

/* ---------------------------------------------------------------------------
 * CWND API
 * ------------------------------------------------------------------------- */

/** Initialize CWND controller with the given MSS. */
void nn_cong_cwnd_init(nn_cong_cwnd *c, uint32_t mss);

/** Process acked bytes.  Grows window based on current phase. */
void nn_cong_cwnd_on_ack(nn_cong_cwnd *c, int32_t acked_bytes);

/**
 * Process a loss event.  Enters Recovery, halves window.
 *
 * loss_seq:  the sequence number where loss was detected
 * now_ns:    current time
 */
void nn_cong_cwnd_on_loss(nn_cong_cwnd *c, uint16_t loss_seq, int64_t now_ns);

/** Can we send a packet of this size? */
static inline int nn_cong_cwnd_can_send(const nn_cong_cwnd *c, int32_t pkt_size) {
    return c->in_flight + pkt_size <= (int32_t)c->cwnd;
}

/** Record a sent packet. */
static inline void nn_cong_cwnd_on_send(nn_cong_cwnd *c, int32_t pkt_size,
                                         int64_t now_ns) {
    c->in_flight      += pkt_size;
    c->last_send_ns    = now_ns;
    c->last_activity_ns = now_ns;
}

/** Minimum interval between sends (nanoseconds).  0 = no pacing. */
int64_t nn_cong_cwnd_pacing_ns(const nn_cong_cwnd *c);

/** Check for idle restart (RFC 2861): 2 RTOs idle → slow start. */
void nn_cong_cwnd_check_idle(nn_cong_cwnd *c, int64_t now_ns, int64_t rto_ns);

/**
 * Notify CWND that a previously in-flight ack has been processed.
 * Decrements in_flight and checks recovery exit via seq comparison.
 *
 * acked_seq:  the sequence number that was acked
 * acked_bytes: number of bytes acked
 */
void nn_cong_cwnd_on_ack_seq(nn_cong_cwnd *c, uint16_t acked_seq,
                              int32_t acked_bytes);

#endif /* NN_CONGESTION_H */
