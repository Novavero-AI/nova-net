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

    /* 8 success + 2 lost = 20% loss */
    nn_loss_window_init(&lw);
    for (int i = 0; i < 8; i++)
        nn_loss_window_record(&lw, 0);
    nn_loss_window_record(&lw, 1);
    nn_loss_window_record(&lw, 1);
    double pct = nn_loss_window_percent(&lw);
    ASSERT("loss_20pct", pct > 0.19 && pct < 0.21);

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

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
