/*
 * test_seq.c — Verify sequence numbers, ring buffers, ACK processing
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -Icbits cbits/nn_seq.c cbits/test_seq.c -o test_seq
 */

#include "nn_seq.h"
#include <stdio.h>
#include <string.h>

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

/* --- Sequence number comparison --- */

static void test_seq_gt(void)
{
    /* Basic comparison */
    ASSERT("1 > 0", nn_seq_gt(1, 0));
    ASSERT("!(0 > 1)", !nn_seq_gt(0, 1));
    ASSERT("!(5 > 5)", !nn_seq_gt(5, 5));

    /* Wraparound: 0 > 65535 (just wrapped) */
    ASSERT("0 > 65535 (wrap)", nn_seq_gt(0, 65535));
    ASSERT("!(65535 > 0 wrap)", !nn_seq_gt(65535, 0));

    /* Antisymmetry: if a > b then !(b > a) */
    ASSERT("100 > 50", nn_seq_gt(100, 50));
    ASSERT("!(50 > 100)", !nn_seq_gt(50, 100));

    /* Half-range boundary */
    ASSERT("32768 > 0", nn_seq_gt(32768, 0));
    ASSERT("!(32769 > 0)", !nn_seq_gt(32769, 0)); /* past half-range */

    /* Near wraparound */
    ASSERT("5 > 65530 (wrap)", nn_seq_gt(5, 65530));
    ASSERT("!(65530 > 5 wrap)", !nn_seq_gt(65530, 5));
}

static void test_seq_diff(void)
{
    ASSERT_EQ("diff(10,5)", 5, nn_seq_diff(10, 5));
    ASSERT_EQ("diff(5,10)", -5, nn_seq_diff(5, 10));
    ASSERT_EQ("diff(0,0)", 0, nn_seq_diff(0, 0));

    /* Wraparound */
    ASSERT_EQ("diff(2,65534)", 4, nn_seq_diff(2, 65534));
    ASSERT_EQ("diff(65534,2)", -4, nn_seq_diff(65534, 2));
}

/* --- Received buffer --- */

static void test_recv_buf(void)
{
    nn_recv_buf buf;
    nn_recv_buf_init(&buf);

    /* Empty buffer: nothing exists */
    ASSERT("empty !exists 42", !nn_recv_buf_exists(&buf, 42));

    /* Insert and check */
    nn_recv_buf_insert(&buf, 42);
    ASSERT("exists 42", nn_recv_buf_exists(&buf, 42));
    ASSERT("!exists 43", !nn_recv_buf_exists(&buf, 43));

    /* Highest tracking */
    ASSERT_EQ("highest=42", 42, buf.highest);
    nn_recv_buf_insert(&buf, 100);
    ASSERT_EQ("highest=100", 100, buf.highest);

    /* Wraparound: seq 0 after 65535 */
    nn_recv_buf_init(&buf);
    nn_recv_buf_insert(&buf, 65535);
    nn_recv_buf_insert(&buf, 0);
    ASSERT("exists 65535", nn_recv_buf_exists(&buf, 65535));
    ASSERT("exists 0", nn_recv_buf_exists(&buf, 0));
    ASSERT_EQ("highest=0 (wrap)", 0, buf.highest);

    /* Hash collision: seq 0 and seq 256 map to same slot */
    nn_recv_buf_init(&buf);
    nn_recv_buf_insert(&buf, 0);
    nn_recv_buf_insert(&buf, 256);
    ASSERT("collision: !exists 0", !nn_recv_buf_exists(&buf, 0));
    ASSERT("collision: exists 256", nn_recv_buf_exists(&buf, 256));
}

/* --- Sent packet buffer --- */

static void test_sent_buf(void)
{
    nn_sent_buf buf;
    nn_sent_buf_init(&buf);
    ASSERT_EQ("empty count", 0, buf.count);

    /* Insert */
    nn_sent_record rec = {
        .channel_id = 0, .channel_seq = 10,
        .send_time_ns = 1000000, .size = 64, .nack_count = 0, .occupied = 1
    };
    nn_sent_buf_insert(&buf, 42, &rec);
    ASSERT_EQ("count after insert", 1, buf.count);
    ASSERT("exists 42", nn_sent_buf_exists(&buf, 42));
    ASSERT("!exists 43", !nn_sent_buf_exists(&buf, 43));

    /* Lookup */
    const nn_sent_record *found = nn_sent_buf_lookup(&buf, 42);
    ASSERT("lookup not null", found != NULL);
    ASSERT_EQ("lookup channel_seq", 10, found->channel_seq);
    ASSERT_EQ("lookup size", 64, (int)found->size);

    /* Lookup miss */
    ASSERT("lookup miss null", nn_sent_buf_lookup(&buf, 99) == NULL);

    /* Delete */
    int deleted = nn_sent_buf_delete(&buf, 42);
    ASSERT_EQ("deleted", 1, deleted);
    ASSERT_EQ("count after delete", 0, buf.count);
    ASSERT("!exists after delete", !nn_sent_buf_exists(&buf, 42));

    /* Delete miss */
    ASSERT_EQ("delete miss", 0, nn_sent_buf_delete(&buf, 42));

    /* Overwrite same slot */
    nn_sent_record rec2 = {
        .channel_id = 1, .channel_seq = 20,
        .send_time_ns = 2000000, .size = 128, .nack_count = 0, .occupied = 1
    };
    nn_sent_buf_insert(&buf, 42, &rec);
    nn_sent_buf_insert(&buf, 42, &rec2);
    ASSERT_EQ("count no double-count", 1, buf.count);
    found = nn_sent_buf_lookup(&buf, 42);
    ASSERT_EQ("overwrite channel_seq", 20, found->channel_seq);
}

/* --- ACK bitfield --- */

static void test_ack_update(void)
{
    uint16_t remote = 0;
    uint64_t bits = 0;

    /* Receive seq 0: first packet */
    nn_ack_update(&remote, &bits, 0);
    ASSERT_EQ("ack remote=0", 0, remote);

    /* Receive seq 1: advances remote, bit 0 set for old remote */
    nn_ack_update(&remote, &bits, 1);
    ASSERT_EQ("ack remote=1", 1, remote);
    ASSERT("ack bit0 set", (bits & 1) != 0);

    /* Receive seq 3: skip seq 2, bits should show gap */
    nn_ack_update(&remote, &bits, 3);
    ASSERT_EQ("ack remote=3", 3, remote);
    /* bit 0 = seq 2 (not received), bit 1 = seq 1 (received) */
    ASSERT("seq2 not acked", (bits & 1) == 0);
    ASSERT("seq1 acked", (bits & 2) != 0);

    /* Receive seq 2 (fill gap): bit 0 should now be set */
    nn_ack_update(&remote, &bits, 2);
    ASSERT_EQ("ack remote still 3", 3, remote);
    ASSERT("seq2 now acked", (bits & 1) != 0);
}

static void test_ack_wraparound(void)
{
    uint16_t remote = 65534;
    uint64_t bits = 0;

    nn_ack_update(&remote, &bits, 65534);
    nn_ack_update(&remote, &bits, 65535);
    ASSERT_EQ("wrap remote=65535", 65535, remote);

    nn_ack_update(&remote, &bits, 0);
    ASSERT_EQ("wrap remote=0", 0, remote);
    ASSERT("wrap 65535 acked", (bits & 1) != 0);
}

/* --- Loss window --- */

static void test_loss_window(void)
{
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    ASSERT("loss_empty", nn_loss_window_percent(&lw) == 0.0);

    /* 10 successes */
    for (int i = 0; i < 10; i++)
        nn_loss_window_record(&lw, 0);
    ASSERT("loss_all_good", nn_loss_window_percent(&lw) == 0.0);

    /* 8 success + 2 lost = 20% loss (exact: 2/10 == 0.2) */
    nn_loss_window_init(&lw);
    for (int i = 0; i < 8; i++)
        nn_loss_window_record(&lw, 0);
    nn_loss_window_record(&lw, 1);
    nn_loss_window_record(&lw, 1);
    ASSERT("loss_20pct", nn_loss_window_percent(&lw) == 0.2);

    /* Fill entire window with losses */
    nn_loss_window_init(&lw);
    for (int i = 0; i < 256; i++)
        nn_loss_window_record(&lw, 1);
    ASSERT("loss_all_bad", nn_loss_window_percent(&lw) == 1.0);
}

/* --- Sequence buffer --- */

static void test_seq_buf(void)
{
    nn_seq_buf buf;
    nn_seq_buf_init(&buf);

    ASSERT("seq_buf empty", !nn_seq_buf_exists(&buf, 42));

    nn_seq_buf_insert(&buf, 42);
    ASSERT("seq_buf exists", nn_seq_buf_exists(&buf, 42));
    ASSERT("seq_buf !exists other", !nn_seq_buf_exists(&buf, 43));

    nn_seq_buf_delete(&buf, 42);
    ASSERT("seq_buf deleted", !nn_seq_buf_exists(&buf, 42));
}

/* --- RNG --- */

static void test_rng(void)
{
    uint64_t state = 12345;
    uint64_t a = nn_rng_next(&state);
    uint64_t b = nn_rng_next(&state);
    ASSERT("rng different outputs", a != b);

    /* Deterministic: same seed, same output */
    uint64_t state2 = 12345;
    uint64_t a2 = nn_rng_next(&state2);
    ASSERT_EQ("rng deterministic", (long long)a, (long long)a2);

    /* Double in [0, 1) */
    double d = nn_rng_double(a);
    ASSERT("rng_double >= 0", d >= 0.0);
    ASSERT("rng_double < 1", d < 1.0);
}

/* --- Boundary tests: half-range symmetry, 0xFFFF sentinel, etc. --- */

static void test_seq_gt_half_range_symmetry(void)
{
    /* At exactly half-range, 32768 > 0 but NOT 0 > 32768 */
    ASSERT("half_32768>0", nn_seq_gt(32768, 0));
    ASSERT("half_!(0>32768)", !nn_seq_gt(0, 32768));

    /* Just past half-range: 32769 is behind 0, not ahead */
    ASSERT("half_!(32769>0)", !nn_seq_gt(32769, 0));
    ASSERT("half_0>32769", nn_seq_gt(0, 32769));
}

static void test_seq_diff_half_range_boundary(void)
{
    /* Exact half-range: diff(32768, 0) = 32768 (positive) */
    ASSERT_EQ("diff_half_pos", 32768, nn_seq_diff(32768, 0));
    /* Exact negative half-range: diff(0, 32768) = -32768 */
    ASSERT_EQ("diff_half_neg", -32768, nn_seq_diff(0, 32768));

    /* One past: diff(32769, 0) wraps to negative */
    ASSERT_EQ("diff_past_half", -32767, nn_seq_diff(32769, 0));
}

static void test_recv_buf_no_false_positive(void)
{
    /* Previously 0xFFFF sentinel caused false positive on fresh buffer */
    nn_recv_buf buf;
    nn_recv_buf_init(&buf);

    ASSERT("no_false_65535", !nn_recv_buf_exists(&buf, 65535));
    ASSERT("no_false_0", !nn_recv_buf_exists(&buf, 0));
    ASSERT("no_false_255", !nn_recv_buf_exists(&buf, 255));

    /* Insert 0xFFFF and verify it works correctly */
    nn_recv_buf_insert(&buf, 65535);
    ASSERT("65535_exists_after_insert", nn_recv_buf_exists(&buf, 65535));
}

static void test_ack_large_gap(void)
{
    /* Gap >= 64 clears entire bitfield */
    uint16_t remote = 0;
    uint64_t bits = 0;

    nn_ack_update(&remote, &bits, 0);
    nn_ack_update(&remote, &bits, 1);
    ASSERT("pre_gap_bit0", (bits & 1) != 0);

    /* Jump by 64: clears all bits */
    nn_ack_update(&remote, &bits, 65);
    ASSERT_EQ("gap64_remote", 65, remote);
    ASSERT_EQ("gap64_bits_cleared", 0, (long long)bits);

    /* Jump by 100: also clears */
    nn_ack_update(&remote, &bits, 200);
    ASSERT_EQ("gap100_bits_cleared", 0, (long long)bits);
}

static void test_loss_window_full_wrap(void)
{
    /* Fill beyond 256 samples — older samples get overwritten */
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* First 256: all success */
    for (int i = 0; i < 256; i++)
        nn_loss_window_record(&lw, 0);
    ASSERT("wrap_all_good", nn_loss_window_percent(&lw) == 0.0);

    /* Next 256: all lost (overwrites the successes) */
    for (int i = 0; i < 256; i++)
        nn_loss_window_record(&lw, 1);
    ASSERT("wrap_all_bad", nn_loss_window_percent(&lw) == 1.0);

    /* Overwrite half with successes (exact: 128/256 == 0.5) */
    for (int i = 0; i < 128; i++)
        nn_loss_window_record(&lw, 0);
    ASSERT("wrap_half", nn_loss_window_percent(&lw) == 0.5);
}

static void test_sent_buf_collision(void)
{
    /* Two different seqs mapping to same slot (seq 0 and seq 256) */
    nn_sent_buf buf;
    nn_sent_buf_init(&buf);

    nn_sent_record rec = {
        .channel_id = 0, .channel_seq = 10,
        .send_time_ns = 1000, .size = 64, .nack_count = 0, .occupied = 1
    };

    nn_sent_buf_insert(&buf, 0, &rec);
    ASSERT("collision_0_exists", nn_sent_buf_exists(&buf, 0));

    rec.channel_seq = 20;
    nn_sent_buf_insert(&buf, 256, &rec);
    /* Seq 0 should be evicted, seq 256 should exist */
    ASSERT("collision_256_exists", nn_sent_buf_exists(&buf, 256));
    ASSERT("collision_0_evicted", !nn_sent_buf_exists(&buf, 0));
    ASSERT_EQ("collision_count", 1, buf.count);
}

static void test_rng_seed_zero(void)
{
    /* Seed 0 should not be degenerate — LCG produces nonzero output */
    uint64_t state = 0;
    uint64_t val = nn_rng_next(&state);
    ASSERT("rng_seed0_nonzero", val != 0);
    ASSERT("rng_seed0_state_advanced", state != 0);
}

static void test_rng_double_extremes(void)
{
    /* val = 0 should produce 0.0 */
    double d0 = nn_rng_double(0);
    ASSERT("rng_double_zero", d0 == 0.0);

    /* val = UINT64_MAX should produce < 1.0 */
    double dmax = nn_rng_double(UINT64_MAX);
    ASSERT("rng_double_max_lt_1", dmax < 1.0);
    ASSERT("rng_double_max_ge_0", dmax >= 0.0);
}

/* --- H-1: nn_sent_buf_insert return values --- */

static void test_sent_buf_insert_return(void)
{
    nn_sent_buf buf;
    nn_sent_buf_init(&buf);

    nn_sent_record rec = {
        .channel_id = 0, .channel_seq = 10,
        .send_time_ns = 1000, .size = 64, .nack_count = 0, .occupied = 1
    };
    nn_sent_record rec2 = {
        .channel_id = 1, .channel_seq = 20,
        .send_time_ns = 2000, .size = 128, .nack_count = 0, .occupied = 1
    };

    /* Insert into empty slot → 0 */
    ASSERT_EQ("insert_empty_rc", 0, nn_sent_buf_insert(&buf, 42, &rec));

    /* Overwrite same seq → 0 (not an eviction) */
    ASSERT_EQ("insert_same_rc", 0, nn_sent_buf_insert(&buf, 42, &rec2));

    /* Evict different seq (42 + 256 maps to same slot) → 1 */
    ASSERT_EQ("insert_evict_rc", 1, nn_sent_buf_insert(&buf, 42 + 256, &rec));
}

/* --- M-8: Duplicate seq in nn_ack_update — verify no-op --- */

static void test_ack_duplicate(void)
{
    uint16_t remote = 0;
    uint64_t bits = 0;

    nn_ack_update(&remote, &bits, 5);
    ASSERT_EQ("dup_remote_5", 5, remote);
    uint64_t bits_before = bits;

    /* Duplicate: diff == 0, neither branch fires → no-op */
    nn_ack_update(&remote, &bits, 5);
    ASSERT_EQ("dup_remote_still_5", 5, remote);
    ASSERT_EQ("dup_bits_unchanged", (long long)bits_before, (long long)bits);
}

int main(void)
{
    test_seq_gt();
    test_seq_diff();
    test_recv_buf();
    test_sent_buf();
    test_ack_update();
    test_ack_wraparound();
    test_loss_window();
    test_seq_buf();
    test_rng();
    test_seq_gt_half_range_symmetry();
    test_seq_diff_half_range_boundary();
    test_recv_buf_no_false_positive();
    test_ack_large_gap();
    test_loss_window_full_wrap();
    test_sent_buf_collision();
    test_rng_seed_zero();
    test_rng_double_extremes();
    test_sent_buf_insert_return();
    test_ack_duplicate();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
