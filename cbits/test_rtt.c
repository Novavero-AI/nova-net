/*
 * test_rtt.c -- Verify Jacobson/Karels RTT estimation
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -Icbits \
 *        cbits/nn_rtt.c cbits/test_rtt.c -o test_rtt
 */

#include "nn_rtt.h"
#include <stdio.h>

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
#define MS(x) ((int64_t)(x) * 1000000LL)

/* --- Init state --- */

static void test_init(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    ASSERT_EQ("init_srtt", NN_RTT_UNINITIALIZED, rtt.srtt_ns);
    ASSERT_EQ("init_rttvar", 0, rtt.rttvar_ns);
    ASSERT_EQ("init_rto", NN_RTT_RTO_MAX_NS, rtt.rto_ns);
    ASSERT_EQ("init_count", 0, (long long)rtt.sample_count);
    ASSERT("init_not_initialized", !nn_rtt_is_initialized(&rtt));
    ASSERT_EQ("init_srtt_getter", 0, nn_rtt_srtt(&rtt));
    ASSERT_EQ("init_rto_getter", NN_RTT_RTO_MAX_NS, nn_rtt_rto(&rtt));
}

/* --- First sample --- */

static void test_first_sample(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, MS(100));

    ASSERT("first_initialized", nn_rtt_is_initialized(&rtt));
    ASSERT_EQ("first_srtt", MS(100), rtt.srtt_ns);
    ASSERT_EQ("first_rttvar", MS(50), rtt.rttvar_ns);
    ASSERT_EQ("first_count", 1, (long long)rtt.sample_count);

    /* RTO = SRTT + max(G, 4*RTTVAR) = 100ms + max(1ms, 200ms) = 300ms */
    ASSERT_EQ("first_rto", MS(300), rtt.rto_ns);
}

/* --- Second sample: EWMA convergence --- */

static void test_second_sample(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, MS(100));
    nn_rtt_update(&rtt, MS(100));

    /* SRTT = 100 - 100/8 + 100/8 = 100ms (same sample) */
    ASSERT_EQ("second_srtt", MS(100), rtt.srtt_ns);
    ASSERT_EQ("second_count", 2, (long long)rtt.sample_count);
}

/* --- Stable samples converge --- */

static void test_stable_convergence(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    for (int i = 0; i < 100; i++)
        nn_rtt_update(&rtt, MS(80));

    /* After many identical samples, SRTT should be very close to 80ms */
    ASSERT("stable_srtt", rtt.srtt_ns >= MS(79) && rtt.srtt_ns <= MS(81));
    /* RTTVAR should converge toward 0 (no variance) */
    ASSERT("stable_rttvar_low", rtt.rttvar_ns < MS(5));
    ASSERT_EQ("stable_count", 100, (long long)rtt.sample_count);
}

/* --- Increasing RTT trends upward --- */

static void test_increasing_rtt(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, MS(50));
    int64_t srtt_before = rtt.srtt_ns;

    nn_rtt_update(&rtt, MS(200));
    ASSERT("increasing_srtt", rtt.srtt_ns > srtt_before);
}

/* --- Decreasing RTT trends downward --- */

static void test_decreasing_rtt(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, MS(200));
    int64_t srtt_before = rtt.srtt_ns;

    nn_rtt_update(&rtt, MS(50));
    ASSERT("decreasing_srtt", rtt.srtt_ns < srtt_before);
}

/* --- Minimum RTO clamp --- */

static void test_rto_min_clamp(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    /* Very small RTT: 1ms */
    for (int i = 0; i < 50; i++)
        nn_rtt_update(&rtt, MS(1));

    ASSERT("rto_min", rtt.rto_ns >= NN_RTT_RTO_MIN_NS);
}

/* --- Maximum RTO clamp --- */

static void test_rto_max_clamp(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    /* Huge RTT: 5000ms (exceeds max) */
    nn_rtt_update(&rtt, MS(5000));

    ASSERT("rto_max", rtt.rto_ns <= NN_RTT_RTO_MAX_NS);
}

/* --- Variance spike increases RTO --- */

static void test_variance_spike(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    /* Stabilize at 50ms */
    for (int i = 0; i < 20; i++)
        nn_rtt_update(&rtt, MS(50));

    int64_t rto_before = rtt.rto_ns;

    /* One outlier at 500ms */
    nn_rtt_update(&rtt, MS(500));

    ASSERT("spike_rto_increased", rtt.rto_ns > rto_before);
    ASSERT("spike_rttvar_increased", rtt.rttvar_ns > MS(50));
}

/* --- Zero sample edge case --- */

static void test_zero_sample(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, 0);

    ASSERT("zero_initialized", nn_rtt_is_initialized(&rtt));
    ASSERT_EQ("zero_srtt", 0, rtt.srtt_ns);
    /* RTO should be at minimum (SRTT=0 + max(G, 0) = G = 1ms, clamped to 50ms) */
    ASSERT_EQ("zero_rto", NN_RTT_RTO_MIN_NS, rtt.rto_ns);
}

/* --- Negative sample rejected --- */

static void test_negative_sample(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, -100);

    ASSERT("neg_not_initialized", !nn_rtt_is_initialized(&rtt));
    ASSERT_EQ("neg_count", 0, (long long)rtt.sample_count);
}

/* --- Large sample near limits --- */

static void test_large_sample(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    /* 1 billion ns = 1 second */
    nn_rtt_update(&rtt, 1000000000LL);
    ASSERT_EQ("large_srtt", 1000000000LL, rtt.srtt_ns);
    ASSERT("large_rto_clamped", rtt.rto_ns <= NN_RTT_RTO_MAX_NS);
}

/* --- Multiple samples track correctly --- */

static void test_sample_count(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, MS(10));
    nn_rtt_update(&rtt, MS(20));
    nn_rtt_update(&rtt, MS(30));
    nn_rtt_update(&rtt, -5);  /* rejected */
    nn_rtt_update(&rtt, MS(40));

    ASSERT_EQ("count_4", 4, (long long)rtt.sample_count);
}

/* --- SRTT getter matches field --- */

static void test_srtt_getter(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    nn_rtt_update(&rtt, MS(75));

    ASSERT_EQ("srtt_getter", rtt.srtt_ns, nn_rtt_srtt(&rtt));
}

/* --- RTO between min and max after normal usage --- */

static void test_rto_bounds(void)
{
    nn_rtt rtt;
    nn_rtt_init(&rtt);

    int64_t samples[] = {MS(10), MS(50), MS(30), MS(80), MS(20), MS(60)};
    for (int i = 0; i < 6; i++)
        nn_rtt_update(&rtt, samples[i]);

    ASSERT("rto_gte_min", rtt.rto_ns >= NN_RTT_RTO_MIN_NS);
    ASSERT("rto_lte_max", rtt.rto_ns <= NN_RTT_RTO_MAX_NS);
}

int main(void)
{
    test_init();
    test_first_sample();
    test_second_sample();
    test_stable_convergence();
    test_increasing_rtt();
    test_decreasing_rtt();
    test_rto_min_clamp();
    test_rto_max_clamp();
    test_variance_spike();
    test_zero_sample();
    test_negative_sample();
    test_large_sample();
    test_sample_count();
    test_srtt_getter();
    test_rto_bounds();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
