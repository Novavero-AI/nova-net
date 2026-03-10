/*
 * test_ack_process.c -- Verify ACK bitfield processing
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -Icbits \
 *        cbits/nn_seq.c cbits/nn_ack_process.c cbits/test_ack_process.c \
 *        -o test_ack_process
 */

#include "nn_ack_process.h"
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

/** Insert a sent record with the given seq, send_time, and size. */
static void
insert_record(nn_sent_buf *buf, uint16_t seq, uint64_t send_time_ns, uint32_t size)
{
    nn_sent_record rec;
    memset(&rec, 0, sizeof(rec));
    rec.channel_id   = 0;
    rec.channel_seq  = seq;
    rec.send_time_ns = send_time_ns;
    rec.size         = size;
    rec.nack_count   = 0;
    rec.occupied     = 1;
    nn_sent_buf_insert(buf, seq, &rec);
}

/* --- Empty sent buffer: no crashes --- */

static void test_empty(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 42, 0x00000000, 1000000, &result);

    ASSERT_EQ("empty_acked", 0, result.acked_count);
    ASSERT_EQ("empty_bytes", 0, result.acked_bytes);
    ASSERT_EQ("empty_rtt", NN_ACK_NO_RTT_SAMPLE, result.rtt_sample_ns);
    ASSERT_EQ("empty_lost", 0, result.lost_count);
    ASSERT_EQ("empty_fast", 0, result.fast_retransmit);
}

/* --- Direct ack only (no bitfield bits set) --- */

static void test_direct_ack(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    insert_record(&sent, 100, 5000000, 64);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 100, 0x00000000, 10000000, &result);

    ASSERT_EQ("direct_acked", 1, result.acked_count);
    ASSERT_EQ("direct_bytes", 64, result.acked_bytes);
    ASSERT_EQ("direct_rtt", 5000000LL, result.rtt_sample_ns);
    ASSERT_EQ("direct_lost", 0, result.lost_count);
    /* Entry should be deleted */
    ASSERT("direct_deleted", !nn_sent_buf_exists(&sent, 100));
}

/* --- Direct ack not found --- */

static void test_direct_not_found(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 100, 0x00000000, 10000000, &result);

    ASSERT_EQ("notfound_acked", 0, result.acked_count);
    ASSERT_EQ("notfound_rtt", NN_ACK_NO_RTT_SAMPLE, result.rtt_sample_ns);
}

/* --- Full bitfield (all 1s): direct + 32 bits = 33 acks --- */

static void test_full_bitfield(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* Insert 33 records: seq 68..100 */
    for (uint16_t s = 68; s <= 100; s++)
        insert_record(&sent, s, 1000000, 100);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 100, 0xFFFFFFFF, 5000000, &result);

    ASSERT_EQ("full_acked", 33, result.acked_count);
    ASSERT_EQ("full_bytes", 3300, result.acked_bytes);
    ASSERT("full_rtt_valid", result.rtt_sample_ns > 0);
    ASSERT_EQ("full_lost", 0, result.lost_count);
}

/* --- No bits set: only direct ack, rest are losses --- */

static void test_no_bits(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* Direct ack + 5 preceding entries */
    insert_record(&sent, 10, 1000000, 50);
    for (uint16_t s = 5; s <= 9; s++)
        insert_record(&sent, s, 1000000, 50);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 10, 0x00000000, 5000000, &result);

    ASSERT_EQ("nobits_acked", 1, result.acked_count);
    /* 5 entries in the bitfield range are present and NOT acked */
    ASSERT_EQ("nobits_lost", 5, result.lost_count);
}

/* --- Alternating bits: half acked, half nacked --- */

static void test_alternating(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* Insert entries for seq 68..100 (33 entries: direct + 32 bitfield) */
    for (uint16_t s = 68; s <= 100; s++)
        insert_record(&sent, s, 1000000, 32);

    /* 0x55555555 = alternating bits: bit 0,2,4,...=1; bit 1,3,5,...=0 */
    nn_ack_result result;
    nn_ack_process(&sent, &lw, 100, 0x55555555, 5000000, &result);

    /* Direct ack (100) + 16 bits set = 17 acked */
    ASSERT_EQ("alt_acked", 17, result.acked_count);
    /* 16 bits clear with entries present = 16 losses */
    ASSERT_EQ("alt_lost", 16, result.lost_count);
}

/* --- Fast retransmit: 3 NACKs triggers --- */

static void test_fast_retransmit(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* Insert a packet at seq 50 */
    insert_record(&sent, 50, 1000000, 64);

    /* Simulate 3 ACKs that don't include seq 50 (bit for seq 50 is clear) */
    nn_ack_result result;

    /* ACK seq=51, bit 0 (seq 50) clear */
    nn_ack_process(&sent, &lw, 51, 0x00000000, 2000000, &result);
    ASSERT_EQ("fr1_fast", 0, result.fast_retransmit);

    nn_ack_process(&sent, &lw, 52, 0x00000000, 3000000, &result);
    ASSERT_EQ("fr2_fast", 0, result.fast_retransmit);

    nn_ack_process(&sent, &lw, 53, 0x00000000, 4000000, &result);
    ASSERT_EQ("fr3_fast", 1, result.fast_retransmit);
    ASSERT_EQ("fr3_seq", 50, result.retransmit_seq);
}

/* --- Fast retransmit NOT triggered at 2 NACKs --- */

static void test_fast_retransmit_threshold(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    insert_record(&sent, 50, 1000000, 64);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 51, 0x00000000, 2000000, &result);
    nn_ack_process(&sent, &lw, 52, 0x00000000, 3000000, &result);
    ASSERT_EQ("fr_thresh_not_triggered", 0, result.fast_retransmit);
}

/* --- Deduplication: ack same seq twice --- */

static void test_dedup(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    insert_record(&sent, 42, 1000000, 100);

    nn_ack_result r1;
    nn_ack_process(&sent, &lw, 42, 0x00000000, 5000000, &r1);
    ASSERT_EQ("dedup_first", 1, r1.acked_count);

    /* Second time: entry already deleted */
    nn_ack_result r2;
    nn_ack_process(&sent, &lw, 42, 0x00000000, 6000000, &r2);
    ASSERT_EQ("dedup_second", 0, r2.acked_count);
    ASSERT_EQ("dedup_rtt", NN_ACK_NO_RTT_SAMPLE, r2.rtt_sample_ns);
}

/* --- Wraparound: ack_seq near 0, bitfield references near 65535 --- */

static void test_wraparound(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* Insert seq 65534 and 65535 */
    insert_record(&sent, 65534, 1000000, 50);
    insert_record(&sent, 65535, 1000000, 50);

    /* ACK seq=0, bit 0 = seq 65535, bit 1 = seq 65534 */
    nn_ack_result result;
    nn_ack_process(&sent, &lw, 0, 0x00000003, 5000000, &result);

    /* No direct ack (seq 0 not in sent_buf) + 2 bitfield acks */
    ASSERT_EQ("wrap_acked", 2, result.acked_count);
    ASSERT("wrap_65535_deleted", !nn_sent_buf_exists(&sent, 65535));
    ASSERT("wrap_65534_deleted", !nn_sent_buf_exists(&sent, 65534));
}

/* --- Loss window integration --- */

static void test_loss_window_fed(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* 5 entries: seq 96..100 */
    for (uint16_t s = 96; s <= 100; s++)
        insert_record(&sent, s, 1000000, 32);

    /* ACK seq=100, bits: only bit 0 (seq 99) set, bits 1-3 clear */
    nn_ack_result result;
    nn_ack_process(&sent, &lw, 100, 0x00000001, 5000000, &result);

    /* Direct ack (100) + bit 0 ack (99) = 2 acked, 3 nacked (98,97,96) */
    ASSERT_EQ("lw_acked", 2, result.acked_count);
    ASSERT_EQ("lw_lost", 3, result.lost_count);

    /* Loss window should have 5 samples total: 2 success, 3 loss */
    double pct = nn_loss_window_percent(&lw);
    ASSERT("lw_pct", pct > 0.5 && pct < 0.7);
}

/* --- acked_bytes accumulation with different sizes --- */

static void test_acked_bytes(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    insert_record(&sent, 10, 1000000, 100);  /* direct ack */
    insert_record(&sent, 9, 1000000, 200);   /* bit 0 */
    insert_record(&sent, 8, 1000000, 300);   /* bit 1 */

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 10, 0x00000003, 5000000, &result);

    ASSERT_EQ("bytes_total", 600, result.acked_bytes);
}

/* --- RTT sample from direct ack only --- */

static void test_rtt_from_direct_only(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* Direct ack at t=1ms, bitfield ack at t=2ms */
    insert_record(&sent, 10, 1000000, 50);
    insert_record(&sent, 9, 2000000, 50);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 10, 0x00000001, 5000000, &result);

    /* RTT sample should be from seq 10 (direct), not seq 9 (bitfield) */
    ASSERT_EQ("rtt_direct", 4000000LL, result.rtt_sample_ns);
}

/* --- Sent buf count decrements correctly --- */

static void test_count_decrement(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    insert_record(&sent, 10, 1000000, 50);
    insert_record(&sent, 9, 1000000, 50);
    insert_record(&sent, 8, 1000000, 50);
    ASSERT_EQ("count_before", 3, sent.count);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 10, 0x00000003, 5000000, &result);

    ASSERT_EQ("count_after", 0, sent.count);
}

/* --- Entries not in bitfield range are untouched --- */

static void test_untouched(void)
{
    nn_sent_buf sent;
    nn_sent_buf_init(&sent);
    nn_loss_window lw;
    nn_loss_window_init(&lw);

    /* Entry far from ack range */
    insert_record(&sent, 200, 1000000, 50);
    insert_record(&sent, 10, 1000000, 50);

    nn_ack_result result;
    nn_ack_process(&sent, &lw, 10, 0x00000000, 5000000, &result);

    /* seq 200 should still exist */
    ASSERT("untouched_200", nn_sent_buf_exists(&sent, 200));
}

int main(void)
{
    test_empty();
    test_direct_ack();
    test_direct_not_found();
    test_full_bitfield();
    test_no_bits();
    test_alternating();
    test_fast_retransmit();
    test_fast_retransmit_threshold();
    test_dedup();
    test_wraparound();
    test_loss_window_fed();
    test_acked_bytes();
    test_rtt_from_direct_only();
    test_count_decrement();
    test_untouched();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
