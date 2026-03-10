/*
 * nn_congestion.c -- Dual-layer congestion control
 */

#include "nn_congestion.h"

/* ---------------------------------------------------------------------------
 * AIMD
 * ------------------------------------------------------------------------- */

void
nn_cong_aimd_init(nn_cong_aimd *c, double base_rate,
                  double loss_threshold, int64_t rtt_threshold_ns)
{
    c->mode             = NN_CONG_GOOD;
    c->send_rate        = base_rate;
    c->base_rate        = base_rate;
    c->budget           = 0.0;
    c->loss_threshold   = loss_threshold;
    c->rtt_threshold_ns = rtt_threshold_ns;
    c->recovery_time_ns = NN_CONG_RECOVERY_MIN_NS;
    c->recovery_start_ns = 0;
    c->last_good_ns     = 0;
}

/** Clamp int64 to [lo, hi]. */
static inline int64_t
clamp_i64(int64_t val, int64_t lo, int64_t hi)
{
    if (val < lo) return lo;
    if (val > hi) return hi;
    return val;
}

void
nn_cong_aimd_tick(nn_cong_aimd *c, double dt_sec,
                  double loss_frac, int64_t srtt_ns, int64_t now_ns)
{
    int conditions_bad = (loss_frac > c->loss_threshold)
                      || (srtt_ns > c->rtt_threshold_ns);

    if (c->mode == NN_CONG_GOOD) {
        if (conditions_bad) {
            /* Good → Bad: multiplicative decrease */
            c->mode = NN_CONG_BAD;
            c->send_rate *= NN_CONG_AIMD_DECREASE;
            if (c->send_rate < NN_CONG_AIMD_MIN_RATE)
                c->send_rate = NN_CONG_AIMD_MIN_RATE;

            /* Adaptive recovery: double if re-entering Bad quickly */
            if (c->recovery_start_ns > 0 &&
                (now_ns - c->recovery_start_ns) < NN_CONG_RECOVERY_DOUBLE_NS)
            {
                c->recovery_time_ns = clamp_i64(
                    c->recovery_time_ns * 2,
                    NN_CONG_RECOVERY_MIN_NS,
                    NN_CONG_RECOVERY_MAX_NS);
            }

            c->recovery_start_ns = now_ns;
            c->last_good_ns = 0;
        } else {
            /* Sustained Good: additive increase */
            double max_rate = c->base_rate * NN_CONG_AIMD_MAX_MULTIPLIER;
            c->send_rate += NN_CONG_AIMD_INCREASE * dt_sec;
            if (c->send_rate > max_rate)
                c->send_rate = max_rate;

            /* Adaptive recovery: halve after sustained good */
            if (c->last_good_ns == 0)
                c->last_good_ns = now_ns;

            if ((now_ns - c->last_good_ns) >= NN_CONG_RECOVERY_HALVE_NS) {
                c->recovery_time_ns = clamp_i64(
                    c->recovery_time_ns / 2,
                    NN_CONG_RECOVERY_MIN_NS,
                    NN_CONG_RECOVERY_MAX_NS);
                c->last_good_ns = now_ns;
            }
        }
    } else {
        /* Bad mode: wait for recovery */
        if (!conditions_bad &&
            (now_ns - c->recovery_start_ns) >= c->recovery_time_ns)
        {
            /* Bad → Good */
            c->mode = NN_CONG_GOOD;
            c->last_good_ns = now_ns;
        }
    }

    /* Refill budget: budget += rate * dt, capped at rate */
    c->budget += c->send_rate * dt_sec;
    if (c->budget > c->send_rate)
        c->budget = c->send_rate;
}

/* ---------------------------------------------------------------------------
 * CWND
 * ------------------------------------------------------------------------- */

void
nn_cong_cwnd_init(nn_cong_cwnd *c, uint32_t mss)
{
    c->phase           = NN_CWND_SLOW_START;
    c->cwnd            = (double)NN_CWND_INITIAL_MSS * (double)mss;
    c->ssthresh        = NN_CWND_SSTHRESH_DEFAULT;
    c->mss             = mss;
    c->in_flight       = 0;
    c->recovery_seq    = 0;
    c->last_send_ns    = 0;
    c->last_activity_ns = 0;
    c->srtt_ns         = 0;
}

void
nn_cong_cwnd_on_ack(nn_cong_cwnd *c, int32_t acked_bytes)
{
    double min_cwnd = (double)NN_CWND_MIN_MSS * (double)c->mss;

    if (c->phase == NN_CWND_SLOW_START) {
        /* Exponential growth: cwnd += acked_bytes */
        c->cwnd += (double)acked_bytes;

        /* Transition to Avoidance if we hit ssthresh */
        if (c->cwnd >= c->ssthresh)
            c->phase = NN_CWND_AVOIDANCE;
    } else if (c->phase == NN_CWND_AVOIDANCE) {
        /* Linear growth: cwnd += MSS * acked_bytes / cwnd */
        if (c->cwnd > 0.0)
            c->cwnd += (double)c->mss * (double)acked_bytes / c->cwnd;
    }
    /* In Recovery: don't grow window, handled by on_ack_seq */

    if (c->cwnd < min_cwnd)
        c->cwnd = min_cwnd;
}

void
nn_cong_cwnd_on_loss(nn_cong_cwnd *c, uint16_t loss_seq, int64_t now_ns)
{
    double min_cwnd = (double)NN_CWND_MIN_MSS * (double)c->mss;

    /* Don't re-enter Recovery if already in Recovery */
    if (c->phase == NN_CWND_RECOVERY)
        return;

    c->ssthresh = c->cwnd / 2.0;
    if (c->ssthresh < min_cwnd)
        c->ssthresh = min_cwnd;

    c->cwnd         = c->ssthresh;
    c->phase        = NN_CWND_RECOVERY;
    c->recovery_seq = loss_seq;
    c->last_activity_ns = now_ns;
}

void
nn_cong_cwnd_on_ack_seq(nn_cong_cwnd *c, uint16_t acked_seq,
                         int32_t acked_bytes)
{
    c->in_flight -= acked_bytes;
    if (c->in_flight < 0)
        c->in_flight = 0;

    /* Exit Recovery when all pre-loss data has been acked */
    if (c->phase == NN_CWND_RECOVERY &&
        nn_seq_gt(acked_seq, c->recovery_seq))
    {
        c->phase = NN_CWND_AVOIDANCE;
    }
}

int64_t
nn_cong_cwnd_pacing_ns(const nn_cong_cwnd *c)
{
    if (c->cwnd <= (double)c->mss || c->srtt_ns <= 0)
        return 0;

    double packets_in_window = c->cwnd / (double)c->mss;
    return (int64_t)((double)c->srtt_ns / packets_in_window);
}

void
nn_cong_cwnd_check_idle(nn_cong_cwnd *c, int64_t now_ns, int64_t rto_ns)
{
    int64_t idle_threshold = NN_CWND_IDLE_RTOS * rto_ns;
    if (idle_threshold <= 0)
        return;

    if ((now_ns - c->last_activity_ns) >= idle_threshold) {
        c->phase    = NN_CWND_SLOW_START;
        c->cwnd     = (double)NN_CWND_INITIAL_MSS * (double)c->mss;
        c->ssthresh = NN_CWND_SSTHRESH_DEFAULT;
    }
}
