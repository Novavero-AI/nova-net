/*
 * nn_bandwidth.c — Sliding window bandwidth tracker
 */

#include "nn_bandwidth.h"
#include <string.h>

/** Nanoseconds per millisecond. */
#define NS_PER_MS 1000000ull

void
nn_bandwidth_init(nn_bandwidth *bw, double window_ms)
{
    memset(bw, 0, sizeof(*bw));
    bw->window_ms = (window_ms > 0.0) ? window_ms : NN_BANDWIDTH_WINDOW_MS;
}

void
nn_bandwidth_record(nn_bandwidth *bw, uint32_t size, uint64_t now_ns)
{
    uint32_t idx = bw->head & NN_BANDWIDTH_MASK;
    bw->timestamps[idx] = now_ns;
    bw->sizes[idx]      = size;
    bw->head++;
    if (bw->count < NN_BANDWIDTH_MAX_SAMPLES)
        bw->count++;
}

double
nn_bandwidth_bps(const nn_bandwidth *bw, uint64_t now_ns)
{
    if (bw->count == 0)
        return 0.0;

    uint64_t window_ns = (uint64_t)(bw->window_ms * (double)NS_PER_MS);
    uint64_t cutoff = (now_ns > window_ns) ? (now_ns - window_ns) : 0;
    uint64_t total_bytes = 0;
    uint64_t oldest = now_ns;

    uint32_t start = bw->head - (uint32_t)bw->count;
    for (int i = 0; i < bw->count; i++) {
        uint32_t idx = (start + (uint32_t)i) & NN_BANDWIDTH_MASK;
        if (bw->timestamps[idx] >= cutoff) {
            total_bytes += bw->sizes[idx];
            if (bw->timestamps[idx] < oldest)
                oldest = bw->timestamps[idx];
        }
    }

    if (total_bytes == 0)
        return 0.0;

    double elapsed_s = (double)(now_ns - oldest) / 1e9;
    if (elapsed_s < 0.001)
        return (double)total_bytes / 0.001; /* avoid division by near-zero */

    return (double)total_bytes / elapsed_s;
}
