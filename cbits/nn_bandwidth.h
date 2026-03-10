/*
 * nn_bandwidth.h — Sliding window bandwidth tracker
 *
 * Tracks bytes sent/received over a configurable time window
 * and reports bytes per second. No heap allocation.
 */

#ifndef NN_BANDWIDTH_H
#define NN_BANDWIDTH_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Default measurement window in milliseconds. */
#define NN_BANDWIDTH_WINDOW_MS 1000.0

/** Maximum samples in the ring buffer. */
#define NN_BANDWIDTH_MAX_SAMPLES 128

/** Mask for ring buffer indexing. */
#define NN_BANDWIDTH_MASK (NN_BANDWIDTH_MAX_SAMPLES - 1)

/* ---------------------------------------------------------------------------
 * Bandwidth tracker
 * ------------------------------------------------------------------------- */

typedef struct {
    uint64_t timestamps[NN_BANDWIDTH_MAX_SAMPLES]; /* nanoseconds */
    uint32_t sizes[NN_BANDWIDTH_MAX_SAMPLES];
    uint32_t head;       /* next write index */
    int      count;      /* current sample count */
    double   window_ms;  /* measurement window */
} nn_bandwidth;

/** Initialize tracker with the given window in milliseconds. */
void nn_bandwidth_init(nn_bandwidth *bw, double window_ms);

/** Record a transfer of `size` bytes at time `now_ns` (nanoseconds). */
void nn_bandwidth_record(nn_bandwidth *bw, uint32_t size, uint64_t now_ns);

/** Compute bytes per second over the current window. */
double nn_bandwidth_bps(const nn_bandwidth *bw, uint64_t now_ns);

#endif /* NN_BANDWIDTH_H */
