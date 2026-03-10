/*
 * nn_rtt.c -- Jacobson/Karels RTT estimation (RFC 6298)
 */

#include "nn_rtt.h"

void
nn_rtt_init(nn_rtt *rtt)
{
    rtt->srtt_ns      = NN_RTT_UNINITIALIZED;
    rtt->rttvar_ns    = 0;
    rtt->rto_ns       = NN_RTT_RTO_MAX_NS;
    rtt->sample_count = 0;
}

/** Clamp value to [lo, hi]. */
static inline int64_t
clamp64(int64_t val, int64_t lo, int64_t hi)
{
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

/** Absolute value of int64_t. */
static inline int64_t
abs64(int64_t val)
{
    return val < 0 ? -val : val;
}

void
nn_rtt_update(nn_rtt *rtt, int64_t sample_ns)
{
    if (sample_ns < 0)
        return;

    rtt->sample_count++;

    if (rtt->srtt_ns == NN_RTT_UNINITIALIZED) {
        /* RFC 6298 §2.2: first measurement */
        rtt->srtt_ns   = sample_ns;
        rtt->rttvar_ns = sample_ns / 2;
    } else {
        /* RFC 6298 §2.3: subsequent measurements
         *   RTTVAR = (1 - beta) * RTTVAR + beta * |SRTT - sample|
         *   SRTT   = (1 - alpha) * SRTT + alpha * sample
         *
         * alpha = 1/8 (shift 3), beta = 1/4 (shift 2)
         */
        int64_t delta     = rtt->srtt_ns - sample_ns;
        int64_t abs_delta = abs64(delta);

        rtt->rttvar_ns = rtt->rttvar_ns
                        - (rtt->rttvar_ns >> NN_RTT_BETA_SHIFT)
                        + (abs_delta >> NN_RTT_BETA_SHIFT);

        rtt->srtt_ns = rtt->srtt_ns
                      - (rtt->srtt_ns >> NN_RTT_ALPHA_SHIFT)
                      + (sample_ns >> NN_RTT_ALPHA_SHIFT);
    }

    /* RFC 6298 §2.4: RTO = SRTT + max(G, K * RTTVAR) */
    int64_t k_rttvar = NN_RTT_RTO_K * rtt->rttvar_ns;
    int64_t grace    = (k_rttvar > NN_RTT_GRANULARITY_NS)
                     ? k_rttvar : NN_RTT_GRANULARITY_NS;

    rtt->rto_ns = clamp64(rtt->srtt_ns + grace,
                           NN_RTT_RTO_MIN_NS,
                           NN_RTT_RTO_MAX_NS);
}
