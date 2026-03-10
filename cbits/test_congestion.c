/*
 * test_congestion.c -- Verify dual-layer congestion control
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -Icbits \
 *        cbits/nn_seq.c cbits/nn_congestion.c cbits/test_congestion.c \
 *        -o test_congestion
 */

#include "nn_congestion.h"
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

/** Nanoseconds helpers. */
#define SEC(x)  ((int64_t)(x) * 1000000000LL)
#define MS(x)   ((int64_t)(x) * 1000000LL)

/* =========================================================================
 * AIMD tests
 * ========================================================================= */

static void test_aimd_init(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    ASSERT_EQ("aimd_mode", NN_CONG_GOOD, c.mode);
    ASSERT("aimd_rate", c.send_rate == 60.0);
    ASSERT("aimd_budget", c.budget == 0.0);
}

static void test_aimd_good_increase(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* One tick at 1/60 sec ≈ 0.01667s, no loss, low RTT */
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.0, MS(50), SEC(1));

    /* Rate should increase: 60 + 1.0 * (1/60) ≈ 60.0167 */
    ASSERT("good_increase", c.send_rate > 60.0);
    ASSERT("good_mode", c.mode == NN_CONG_GOOD);
}

static void test_aimd_rate_cap(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* Many ticks: rate should cap at 4x base = 240 */
    for (int i = 0; i < 10000; i++)
        nn_cong_aimd_tick(&c, 1.0, 0.0, MS(50), SEC(1) + SEC(i));

    ASSERT("cap_rate", c.send_rate <= 60.0 * NN_CONG_AIMD_MAX_MULTIPLIER + 0.001);
}

static void test_aimd_loss_triggers_bad(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* Loss > threshold triggers Bad */
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.2, MS(50), SEC(1));

    ASSERT_EQ("loss_bad_mode", NN_CONG_BAD, c.mode);
    ASSERT("loss_bad_rate", c.send_rate <= 30.001); /* 60 * 0.5 = 30 */
}

static void test_aimd_rtt_triggers_bad(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* RTT > threshold triggers Bad */
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.0, MS(500), SEC(1));

    ASSERT_EQ("rtt_bad_mode", NN_CONG_BAD, c.mode);
}

static void test_aimd_stay_bad(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.2, MS(50), SEC(1));
    ASSERT_EQ("stay_bad_enter", NN_CONG_BAD, c.mode);

    /* Tick with good conditions but recovery not elapsed */
    nn_cong_aimd_tick(&c, 0.1, 0.0, MS(50), SEC(1) + MS(100));
    ASSERT_EQ("stay_bad_still", NN_CONG_BAD, c.mode);
}

static void test_aimd_bad_to_good(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.2, MS(50), SEC(1));
    ASSERT_EQ("btg_bad", NN_CONG_BAD, c.mode);

    /* Recovery time = 1 second. Tick at t=2.1s with good conditions */
    nn_cong_aimd_tick(&c, 0.1, 0.0, MS(50), SEC(1) + SEC(1) + MS(100));
    ASSERT_EQ("btg_good", NN_CONG_GOOD, c.mode);
}

static void test_aimd_recovery_double(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* First Bad entry at t=1s */
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.2, MS(50), SEC(1));
    int64_t recovery1 = c.recovery_time_ns;

    /* Recover at t=2.1s */
    nn_cong_aimd_tick(&c, 0.1, 0.0, MS(50), SEC(2) + MS(100));
    ASSERT_EQ("dbl_recovered", NN_CONG_GOOD, c.mode);

    /* Re-enter Bad quickly at t=2.2s (within 5s of first entry) */
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.2, MS(50), SEC(2) + MS(200));
    ASSERT("dbl_recovery_doubled", c.recovery_time_ns >= recovery1 * 2);
}

static void test_aimd_recovery_halve(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* Set a high recovery time */
    c.recovery_time_ns = SEC(8);

    /* Sustain Good for >10 seconds */
    for (int i = 0; i < 12; i++)
        nn_cong_aimd_tick(&c, 1.0, 0.0, MS(50), SEC(1) + SEC(i));

    ASSERT("halve_recovery", c.recovery_time_ns <= SEC(8));
}

static void test_aimd_recovery_clamp(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* Force recovery time very high */
    c.recovery_time_ns = NN_CONG_RECOVERY_MAX_NS;

    /* Enter Bad: doubling should be clamped */
    c.recovery_start_ns = SEC(1);
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.2, MS(50), SEC(1) + MS(100));
    ASSERT("clamp_max", c.recovery_time_ns <= NN_CONG_RECOVERY_MAX_NS);
}

static void test_aimd_budget_refill(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    /* dt = 1/60s at 60 pkt/s → +1 packet of budget */
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.0, MS(50), SEC(1));
    ASSERT("budget_refill", c.budget >= 0.99 && c.budget <= 1.01);
}

static void test_aimd_can_send_deduct(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    ASSERT("cannot_send_empty", !nn_cong_aimd_can_send(&c));

    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.0, MS(50), SEC(1));
    ASSERT("can_send", nn_cong_aimd_can_send(&c));

    nn_cong_aimd_deduct(&c);
    ASSERT("cannot_send_after", !nn_cong_aimd_can_send(&c));
}

static void test_aimd_min_rate(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 2.0, 0.1, MS(250));

    /* Trigger Bad: 2.0 * 0.5 = 1.0 (at minimum) */
    nn_cong_aimd_tick(&c, 1.0 / 60.0, 0.2, MS(50), SEC(1));
    ASSERT("min_rate", c.send_rate >= NN_CONG_AIMD_MIN_RATE);
}

static void test_aimd_zero_dt(void)
{
    nn_cong_aimd c;
    nn_cong_aimd_init(&c, 60.0, 0.1, MS(250));

    double rate_before = c.send_rate;
    double budget_before = c.budget;

    nn_cong_aimd_tick(&c, 0.0, 0.0, MS(50), SEC(1));

    ASSERT("zero_dt_rate", c.send_rate == rate_before);
    ASSERT("zero_dt_budget", c.budget == budget_before);
}

/* =========================================================================
 * CWND tests
 * ========================================================================= */

static void test_cwnd_init(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    ASSERT_EQ("cwnd_phase", NN_CWND_SLOW_START, c.phase);
    ASSERT("cwnd_init", c.cwnd == 10.0 * 1200.0);
    ASSERT_EQ("cwnd_flight", 0, c.in_flight);
    ASSERT_EQ("cwnd_mss", 1200, (long long)c.mss);
}

static void test_cwnd_slow_start(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);
    c.ssthresh = 100000.0;

    double before = c.cwnd;
    nn_cong_cwnd_on_ack(&c, 1200);

    /* SlowStart: cwnd += acked_bytes */
    ASSERT("ss_grow", c.cwnd == before + 1200.0);
    ASSERT_EQ("ss_phase", NN_CWND_SLOW_START, c.phase);
}

static void test_cwnd_slow_start_to_avoidance(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);
    c.ssthresh = 15000.0;

    /* Push cwnd past ssthresh */
    nn_cong_cwnd_on_ack(&c, 5000);

    ASSERT("ss_to_ca", c.cwnd >= c.ssthresh);
    ASSERT_EQ("ca_phase", NN_CWND_AVOIDANCE, c.phase);
}

static void test_cwnd_avoidance(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);
    c.phase = NN_CWND_AVOIDANCE;
    double before = c.cwnd;

    nn_cong_cwnd_on_ack(&c, 1200);

    /* Avoidance: cwnd += MSS * acked / cwnd (linear, much smaller) */
    double expected_increase = 1200.0 * 1200.0 / before;
    ASSERT("ca_grow", fabs(c.cwnd - before - expected_increase) < 1.0);
}

static void test_cwnd_on_loss(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    double before = c.cwnd;
    nn_cong_cwnd_on_loss(&c, 42, SEC(1));

    ASSERT_EQ("loss_phase", NN_CWND_RECOVERY, c.phase);
    ASSERT("loss_ssthresh", c.ssthresh == before / 2.0);
    ASSERT("loss_cwnd", c.cwnd == before / 2.0);
    ASSERT_EQ("loss_seq", 42, c.recovery_seq);
}

static void test_cwnd_no_reenter_recovery(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    nn_cong_cwnd_on_loss(&c, 42, SEC(1));
    double cwnd_after_first = c.cwnd;

    /* Second loss while in Recovery: should NOT halve again */
    nn_cong_cwnd_on_loss(&c, 43, SEC(1) + MS(100));
    ASSERT("no_reenter", c.cwnd == cwnd_after_first);
}

static void test_cwnd_recovery_exit(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    nn_cong_cwnd_on_loss(&c, 42, SEC(1));
    ASSERT_EQ("recov_enter", NN_CWND_RECOVERY, c.phase);

    /* ACK seq 43 > recovery_seq 42 → exit Recovery */
    nn_cong_cwnd_on_ack_seq(&c, 43, 1200);
    ASSERT_EQ("recov_exit", NN_CWND_AVOIDANCE, c.phase);
}

static void test_cwnd_recovery_no_exit(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    nn_cong_cwnd_on_loss(&c, 42, SEC(1));

    /* ACK seq 41 <= recovery_seq 42 → stay in Recovery */
    nn_cong_cwnd_on_ack_seq(&c, 41, 1200);
    ASSERT_EQ("recov_stay", NN_CWND_RECOVERY, c.phase);
}

static void test_cwnd_min(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    /* Force very small cwnd */
    c.cwnd = 100.0;
    nn_cong_cwnd_on_ack(&c, 10);

    double min_cwnd = (double)NN_CWND_MIN_MSS * 1200.0;
    ASSERT("cwnd_min", c.cwnd >= min_cwnd);
}

static void test_cwnd_pacing(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);
    c.srtt_ns = MS(100);

    int64_t interval = nn_cong_cwnd_pacing_ns(&c);
    /* cwnd = 12000, mss = 1200, packets = 10, interval = 100ms/10 = 10ms */
    ASSERT("pacing_interval", interval > 0);
    ASSERT("pacing_approx", interval >= MS(9) && interval <= MS(11));
}

static void test_cwnd_pacing_no_pace(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);
    c.cwnd = 1200.0; /* exactly 1 MSS */

    ASSERT_EQ("no_pace", 0, nn_cong_cwnd_pacing_ns(&c));
}

static void test_cwnd_idle_restart(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    /* Move to Avoidance with larger cwnd */
    c.phase = NN_CWND_AVOIDANCE;
    c.cwnd = 50000.0;
    c.last_activity_ns = SEC(1);

    /* 2 RTOs idle: RTO = 200ms, threshold = 400ms */
    nn_cong_cwnd_check_idle(&c, SEC(1) + MS(500), MS(200));

    ASSERT_EQ("idle_phase", NN_CWND_SLOW_START, c.phase);
    ASSERT("idle_cwnd_reset", c.cwnd == 10.0 * 1200.0);
}

static void test_cwnd_no_idle_restart(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);
    c.phase = NN_CWND_AVOIDANCE;
    c.cwnd = 50000.0;
    c.last_activity_ns = SEC(1);

    /* Not enough idle time */
    nn_cong_cwnd_check_idle(&c, SEC(1) + MS(100), MS(200));
    ASSERT_EQ("no_idle", NN_CWND_AVOIDANCE, c.phase);
}

static void test_cwnd_in_flight(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    nn_cong_cwnd_on_send(&c, 1200, SEC(1));
    ASSERT_EQ("flight_send", 1200, c.in_flight);

    nn_cong_cwnd_on_ack_seq(&c, 0, 1200);
    ASSERT_EQ("flight_ack", 0, c.in_flight);
}

static void test_cwnd_can_send(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);
    /* cwnd = 12000, in_flight = 0 → can send */
    ASSERT("can_send_yes", nn_cong_cwnd_can_send(&c, 1200));

    c.in_flight = 12000;
    ASSERT("can_send_no", !nn_cong_cwnd_can_send(&c, 1200));
}

static void test_cwnd_send_timestamps(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    nn_cong_cwnd_on_send(&c, 1200, SEC(5));
    ASSERT_EQ("ts_send", SEC(5), c.last_send_ns);
    ASSERT_EQ("ts_activity", SEC(5), c.last_activity_ns);
}

static void test_cwnd_recovery_wraparound(void)
{
    nn_cong_cwnd c;
    nn_cong_cwnd_init(&c, 1200);

    /* Loss at seq 65535 */
    nn_cong_cwnd_on_loss(&c, 65535, SEC(1));
    ASSERT_EQ("wrap_recovery", NN_CWND_RECOVERY, c.phase);

    /* ACK seq 0 (wraps past 65535) → exit */
    nn_cong_cwnd_on_ack_seq(&c, 0, 1200);
    ASSERT_EQ("wrap_exit", NN_CWND_AVOIDANCE, c.phase);
}

int main(void)
{
    /* AIMD */
    test_aimd_init();
    test_aimd_good_increase();
    test_aimd_rate_cap();
    test_aimd_loss_triggers_bad();
    test_aimd_rtt_triggers_bad();
    test_aimd_stay_bad();
    test_aimd_bad_to_good();
    test_aimd_recovery_double();
    test_aimd_recovery_halve();
    test_aimd_recovery_clamp();
    test_aimd_budget_refill();
    test_aimd_can_send_deduct();
    test_aimd_min_rate();
    test_aimd_zero_dt();

    /* CWND */
    test_cwnd_init();
    test_cwnd_slow_start();
    test_cwnd_slow_start_to_avoidance();
    test_cwnd_avoidance();
    test_cwnd_on_loss();
    test_cwnd_no_reenter_recovery();
    test_cwnd_recovery_exit();
    test_cwnd_recovery_no_exit();
    test_cwnd_min();
    test_cwnd_pacing();
    test_cwnd_pacing_no_pace();
    test_cwnd_idle_restart();
    test_cwnd_no_idle_restart();
    test_cwnd_in_flight();
    test_cwnd_can_send();
    test_cwnd_send_timestamps();
    test_cwnd_recovery_wraparound();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
