/*
 * test_bandwidth.c — Verify sliding window bandwidth tracker
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -Icbits \
 *        cbits/nn_bandwidth.c cbits/test_bandwidth.c \
 *        -o test_bandwidth
 */

#include "nn_bandwidth.h"
#include <stdio.h>
#include <math.h>

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT(label, cond) do {                                        \
    tests_run++;                                                        \
    if (cond) { tests_passed++; }                                       \
    else { printf("FAIL %s\n", (label)); }                              \
} while (0)

#define ASSERT_EQ(label, expected, actual) do {                         \
    tests_run++;                                                        \
    if ((expected) == (actual)) { tests_passed++; }                     \
    else { printf("FAIL %s: expected %lld, got %lld\n", (label),        \
           (long long)(expected), (long long)(actual)); }               \
} while (0)

/** Nanoseconds per millisecond. */
#define NS_PER_MS 1000000ull

/** Nanoseconds per second. */
#define NS_PER_SEC 1000000000ull

/* --- Empty tracker --- */

static void test_empty_tracker(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    ASSERT("empty_bps_zero", nn_bandwidth_bps(&bw, 1 * NS_PER_SEC) == 0.0);
    ASSERT_EQ("empty_count", 0, bw.count);
    ASSERT_EQ("empty_head", 0, (int)bw.head);
}

/* --- Single sample --- */

static void test_single_sample(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    nn_bandwidth_record(&bw, 1000, 100 * NS_PER_MS);
    ASSERT_EQ("single_count", 1, bw.count);

    /* Query at the same time as the sample — near-zero elapsed,
     * hits the 0.001s floor: 1000 / 0.001 = 1,000,000 */
    double bps = nn_bandwidth_bps(&bw, 100 * NS_PER_MS);
    ASSERT("single_floor", bps >= 999000.0 && bps <= 1001000.0);
}

/* --- Multiple samples over time --- */

static void test_multiple_samples(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    /* Record 100 bytes every 100ms for 1 second = 10 samples */
    for (int i = 0; i < 10; i++) {
        uint64_t t = (uint64_t)(100 + i * 100) * NS_PER_MS;
        nn_bandwidth_record(&bw, 100, t);
    }
    ASSERT_EQ("multi_count", 10, bw.count);

    /* Query at t=1100ms. Window is 1000ms, so all samples are within window.
     * 10 * 100 = 1000 bytes over ~900ms = ~1111 bytes/sec */
    double bps = nn_bandwidth_bps(&bw, 1100 * NS_PER_MS);
    ASSERT("multi_bps_range", bps >= 999.0 && bps <= 1300.0);
}

/* --- Window expiry --- */

static void test_window_expiry(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    /* Record at t=100ms */
    nn_bandwidth_record(&bw, 5000, 100 * NS_PER_MS);

    /* Query far in the future — sample should be expired */
    double bps = nn_bandwidth_bps(&bw, 5000 * NS_PER_MS);
    ASSERT("expired_bps_zero", bps == 0.0);
}

/* --- Ring buffer overflow (>128 samples) --- */

static void test_ring_overflow(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    /* Insert 200 samples — exceeds ring buffer capacity of 128 */
    for (int i = 0; i < 200; i++) {
        uint64_t t = (uint64_t)(500 + i) * NS_PER_MS;
        nn_bandwidth_record(&bw, 10, t);
    }

    /* Count should cap at 128 */
    ASSERT_EQ("overflow_count", NN_BANDWIDTH_MAX_SAMPLES, bw.count);

    /* Should still compute valid bps from the most recent 128 samples */
    double bps = nn_bandwidth_bps(&bw, 700 * NS_PER_MS);
    ASSERT("overflow_bps_positive", bps > 0.0);
}

/* --- Near-zero elapsed (all samples at same timestamp) --- */

static void test_near_zero_elapsed(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    /* 5 samples at the exact same timestamp */
    for (int i = 0; i < 5; i++) {
        nn_bandwidth_record(&bw, 200, 500 * NS_PER_MS);
    }

    /* Query at the same timestamp — should hit the 0.001s floor */
    double bps = nn_bandwidth_bps(&bw, 500 * NS_PER_MS);
    /* 5 * 200 = 1000 bytes / 0.001s = 1,000,000 bytes/sec */
    ASSERT("zero_elapsed_floor", bps >= 999000.0 && bps <= 1001000.0);
}

/* --- Custom window size --- */

static void test_custom_window(void)
{
    nn_bandwidth bw;
    double short_window = 200.0; /* 200ms */
    nn_bandwidth_init(&bw, short_window);

    /* Record at t=100ms and t=500ms */
    nn_bandwidth_record(&bw, 1000, 100 * NS_PER_MS);
    nn_bandwidth_record(&bw, 1000, 500 * NS_PER_MS);

    /* Query at t=600ms with 200ms window: only t=500ms sample is in window */
    double bps = nn_bandwidth_bps(&bw, 600 * NS_PER_MS);
    /* 1000 bytes over 100ms = 10,000 bytes/sec */
    ASSERT("short_window_bps", bps > 9000.0 && bps < 11000.0);
}

/* --- All samples expired --- */

static void test_all_expired(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    nn_bandwidth_record(&bw, 100, 100 * NS_PER_MS);
    nn_bandwidth_record(&bw, 200, 200 * NS_PER_MS);
    nn_bandwidth_record(&bw, 300, 300 * NS_PER_MS);

    /* All samples older than 1000ms window */
    double bps = nn_bandwidth_bps(&bw, 10 * NS_PER_SEC);
    ASSERT("all_expired_zero", bps == 0.0);
}

/* --- Record after expiry --- */

static void test_record_after_expiry(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, NN_BANDWIDTH_WINDOW_MS);

    /* Old sample */
    nn_bandwidth_record(&bw, 5000, 100 * NS_PER_MS);

    /* New sample much later */
    nn_bandwidth_record(&bw, 2000, 5000 * NS_PER_MS);

    /* Query — only new sample is in window */
    double bps = nn_bandwidth_bps(&bw, 5000 * NS_PER_MS);
    /* 2000 bytes / 0.001s (floor) = 2,000,000 */
    ASSERT("after_expiry_new_only", bps > 0.0);
}

/* --- Init zeroes state --- */

static void test_init_state(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, 500.0);

    ASSERT_EQ("init_head", 0, (int)bw.head);
    ASSERT_EQ("init_count", 0, bw.count);
    ASSERT("init_window", fabs(bw.window_ms - 500.0) < 0.001);
}

/* --- H-6: window_ms <= 0 falls back to default --- */

static void test_zero_window(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, 0.0);

    /* Should fall back to default window */
    ASSERT("zero_window_default", fabs(bw.window_ms - NN_BANDWIDTH_WINDOW_MS) < 0.001);

    /* Should still function correctly */
    nn_bandwidth_record(&bw, 1000, 100 * NS_PER_MS);
    double bps = nn_bandwidth_bps(&bw, 200 * NS_PER_MS);
    ASSERT("zero_window_bps", bps > 0.0);
}

static void test_negative_window(void)
{
    nn_bandwidth bw;
    nn_bandwidth_init(&bw, -100.0);

    /* Should fall back to default window */
    ASSERT("neg_window_default", fabs(bw.window_ms - NN_BANDWIDTH_WINDOW_MS) < 0.001);
}

int main(void)
{
    test_empty_tracker();
    test_single_sample();
    test_multiple_samples();
    test_window_expiry();
    test_ring_overflow();
    test_near_zero_elapsed();
    test_custom_window();
    test_all_expired();
    test_record_after_expiry();
    test_init_state();
    test_zero_window();
    test_negative_window();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
