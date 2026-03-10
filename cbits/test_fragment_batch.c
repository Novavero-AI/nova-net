/*
 * test_fragment_batch.c — Verify fragmentation and message batching
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -Icbits \
 *        cbits/nn_fragment.c cbits/nn_batch.c cbits/test_fragment_batch.c \
 *        -o test_fragment_batch
 */

#include "nn_fragment.h"
#include "nn_batch.h"
#include "nn_wire.h"
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

/* --- Fragment header roundtrip --- */

static void test_fragment_header_roundtrip(void)
{
    nn_fragment_header hdr = {
        .message_id = 0xDEADBEEF,
        .fragment_index = 3,
        .fragment_count = 10
    };
    uint8_t buf[NN_FRAGMENT_HEADER_SIZE];
    nn_fragment_write(&hdr, buf);

    nn_fragment_header out;
    int rc = nn_fragment_read(buf, NN_FRAGMENT_HEADER_SIZE, &out);
    ASSERT_EQ("frag_hdr rc", 0, rc);
    ASSERT_EQ("frag_hdr msg_id", (long long)0xDEADBEEF, (long long)out.message_id);
    ASSERT_EQ("frag_hdr index", 3, out.fragment_index);
    ASSERT_EQ("frag_hdr count", 10, out.fragment_count);
}

static void test_fragment_header_truncated(void)
{
    uint8_t buf[3] = {0};
    nn_fragment_header out;
    ASSERT_EQ("frag_hdr_short", -1, nn_fragment_read(buf, 3, &out));
}

static void test_fragment_header_invalid(void)
{
    uint8_t buf[NN_FRAGMENT_HEADER_SIZE];
    nn_fragment_header out;

    /* fragment_count = 0 → nn_fragment_read rejects
     * (write the bytes manually since nn_fragment_write now validates) */
    memset(buf, 0, sizeof(buf));
    nn_write_u32le(buf, 1);
    buf[4] = 0;  /* fragment_index */
    buf[5] = 0;  /* fragment_count = 0 */
    ASSERT_EQ("frag_hdr_count_zero", -1, nn_fragment_read(buf, NN_FRAGMENT_HEADER_SIZE, &out));

    /* fragment_index >= fragment_count → invalid */
    nn_write_u32le(buf, 2);
    buf[4] = 5;  /* index */
    buf[5] = 5;  /* count */
    ASSERT_EQ("frag_hdr_idx_eq_cnt", -1, nn_fragment_read(buf, NN_FRAGMENT_HEADER_SIZE, &out));

    /* fragment_index > fragment_count → invalid */
    nn_write_u32le(buf, 3);
    buf[4] = 10; /* index */
    buf[5] = 3;  /* count */
    ASSERT_EQ("frag_hdr_idx_gt_cnt", -1, nn_fragment_read(buf, NN_FRAGMENT_HEADER_SIZE, &out));

    /* Max valid: index=254, count=255 → valid */
    nn_fragment_header hdr_max = { .message_id = 4, .fragment_index = 254, .fragment_count = 255 };
    nn_fragment_write(&hdr_max, buf);
    ASSERT_EQ("frag_hdr_max_valid", 0, nn_fragment_read(buf, NN_FRAGMENT_HEADER_SIZE, &out));
    ASSERT_EQ("frag_hdr_max_idx", 254, out.fragment_index);
    ASSERT_EQ("frag_hdr_max_cnt", 255, out.fragment_count);
}

/* --- Fragment count --- */

static void test_fragment_count(void)
{
    /* 250 bytes at 100/fragment = 3 fragments */
    ASSERT_EQ("frag_count_250", 3, nn_fragment_count(250, 100));
    /* Exact fit: 200 bytes at 100/fragment = 2 */
    ASSERT_EQ("frag_count_200", 2, nn_fragment_count(200, 100));
    /* Single fragment */
    ASSERT_EQ("frag_count_50", 1, nn_fragment_count(50, 100));
    /* Empty */
    ASSERT_EQ("frag_count_0", 0, nn_fragment_count(0, 100));
    /* Too many fragments */
    ASSERT_EQ("frag_count_too_many", -1, nn_fragment_count(256 * 100, 100));
    /* CRIT-1: max_payload = 0 → error (division by zero guarded) */
    ASSERT_EQ("frag_count_payload_0", -1, nn_fragment_count(100, 0));
}

/* --- Fragment build --- */

static void test_fragment_build(void)
{
    uint8_t msg[250];
    for (int i = 0; i < 250; i++) msg[i] = (uint8_t)(i & 0xFF);

    uint8_t out[NN_FRAGMENT_HEADER_SIZE + 100];

    /* First fragment: bytes 0-99 */
    int len0 = nn_fragment_build(msg, 250, 42, 0, 3, 100, out);
    ASSERT_EQ("frag0_len", NN_FRAGMENT_HEADER_SIZE + 100, len0);

    nn_fragment_header hdr;
    nn_fragment_read(out, (size_t)len0, &hdr);
    ASSERT_EQ("frag0_msg_id", 42, (int)hdr.message_id);
    ASSERT_EQ("frag0_index", 0, hdr.fragment_index);
    ASSERT_EQ("frag0_count", 3, hdr.fragment_count);
    ASSERT("frag0_payload", memcmp(out + NN_FRAGMENT_HEADER_SIZE, msg, 100) == 0);

    /* Last fragment: bytes 200-249 (50 bytes) */
    int len2 = nn_fragment_build(msg, 250, 42, 2, 3, 100, out);
    ASSERT_EQ("frag2_len", NN_FRAGMENT_HEADER_SIZE + 50, len2);
    ASSERT("frag2_payload", memcmp(out + NN_FRAGMENT_HEADER_SIZE, msg + 200, 50) == 0);

    /* Invalid fragment index */
    ASSERT_EQ("frag_bad_index", -1, nn_fragment_build(msg, 250, 42, 3, 3, 100, out));
}

/* --- Batch writer/reader roundtrip --- */

static void test_batch_roundtrip(void)
{
    uint8_t buf[1200];
    nn_batch_writer writer;
    nn_batch_writer_init(&writer, buf, sizeof(buf));

    const uint8_t msg1[] = "hello";
    const uint8_t msg2[] = "world";
    const uint8_t msg3[] = "nova-net";

    ASSERT_EQ("batch_add1", 0, nn_batch_writer_add(&writer, msg1, 5));
    ASSERT_EQ("batch_add2", 0, nn_batch_writer_add(&writer, msg2, 5));
    ASSERT_EQ("batch_add3", 0, nn_batch_writer_add(&writer, msg3, 8));

    size_t total = nn_batch_writer_finish(&writer);
    ASSERT("batch_total > 0", total > 0);
    /* 1 (count) + 3*(2 (len) + payload) = 1 + (7+7+10) = 25 */
    ASSERT_EQ("batch_total_size", 25, (int)total);

    /* Read back */
    nn_batch_reader reader;
    int rc = nn_batch_reader_init(&reader, buf, total);
    ASSERT_EQ("batch_read_init", 0, rc);
    ASSERT_EQ("batch_count", 3, reader.count);

    const uint8_t *out_msg;
    size_t out_len;

    ASSERT_EQ("batch_next1", 0, nn_batch_reader_next(&reader, &out_msg, &out_len));
    ASSERT_EQ("batch_len1", 5, (int)out_len);
    ASSERT("batch_data1", memcmp(out_msg, msg1, 5) == 0);

    ASSERT_EQ("batch_next2", 0, nn_batch_reader_next(&reader, &out_msg, &out_len));
    ASSERT_EQ("batch_len2", 5, (int)out_len);
    ASSERT("batch_data2", memcmp(out_msg, msg2, 5) == 0);

    ASSERT_EQ("batch_next3", 0, nn_batch_reader_next(&reader, &out_msg, &out_len));
    ASSERT_EQ("batch_len3", 8, (int)out_len);
    ASSERT("batch_data3", memcmp(out_msg, msg3, 8) == 0);

    /* No more messages */
    ASSERT_EQ("batch_done", -1, nn_batch_reader_next(&reader, &out_msg, &out_len));
}

static void test_batch_overflow(void)
{
    uint8_t buf[16]; /* tiny buffer */
    nn_batch_writer writer;
    nn_batch_writer_init(&writer, buf, sizeof(buf));

    uint8_t big[20];
    memset(big, 0xAA, sizeof(big));

    /* Can't fit 20-byte message in 16-byte buffer */
    ASSERT_EQ("batch_overflow", -1, nn_batch_writer_add(&writer, big, 20));

    /* Empty batch */
    ASSERT_EQ("batch_empty", 0, (int)nn_batch_writer_finish(&writer));
}

static void test_batch_empty_buf(void)
{
    nn_batch_reader reader;
    /* Empty buffer */
    ASSERT_EQ("batch_read_empty", -1, nn_batch_reader_init(&reader, NULL, 0));
}

static void test_batch_single_message(void)
{
    uint8_t buf[1200];
    nn_batch_writer writer;
    nn_batch_writer_init(&writer, buf, sizeof(buf));

    uint8_t msg[64];
    memset(msg, 0xCD, sizeof(msg));

    nn_batch_writer_add(&writer, msg, 64);
    size_t total = nn_batch_writer_finish(&writer);
    ASSERT_EQ("batch_single_total", 1 + 2 + 64, (int)total);

    nn_batch_reader reader;
    nn_batch_reader_init(&reader, buf, total);

    const uint8_t *out_msg;
    size_t out_len;
    ASSERT_EQ("batch_single_next", 0, nn_batch_reader_next(&reader, &out_msg, &out_len));
    ASSERT_EQ("batch_single_len", 64, (int)out_len);
    ASSERT("batch_single_data", memcmp(out_msg, msg, 64) == 0);
}

/* --- M-2: nn_fragment_write validates headers --- */

static void test_fragment_write_validation(void)
{
    uint8_t buf[NN_FRAGMENT_HEADER_SIZE];

    /* Valid header */
    nn_fragment_header hdr_ok = { .message_id = 1, .fragment_index = 0, .fragment_count = 1 };
    ASSERT_EQ("frag_write_ok", NN_FRAGMENT_HEADER_SIZE, nn_fragment_write(&hdr_ok, buf));

    /* count = 0 → error */
    nn_fragment_header hdr_zero = { .message_id = 1, .fragment_index = 0, .fragment_count = 0 };
    ASSERT_EQ("frag_write_count_zero", -1, nn_fragment_write(&hdr_zero, buf));

    /* index >= count → error */
    nn_fragment_header hdr_oob = { .message_id = 1, .fragment_index = 5, .fragment_count = 5 };
    ASSERT_EQ("frag_write_idx_eq_cnt", -1, nn_fragment_write(&hdr_oob, buf));

    /* index > count → error */
    nn_fragment_header hdr_far = { .message_id = 1, .fragment_index = 10, .fragment_count = 3 };
    ASSERT_EQ("frag_write_idx_gt_cnt", -1, nn_fragment_write(&hdr_far, buf));
}

/* --- M-9: fragment count boundary (255 OK, 256 fails) --- */

static void test_fragment_count_boundary(void)
{
    /* 255 fragments (1 byte each): OK */
    ASSERT_EQ("frag_255_ok", 255, nn_fragment_count(255, 1));
    /* 256 fragments: exceeds NN_MAX_FRAGMENT_COUNT (255) */
    ASSERT_EQ("frag_256_fail", -1, nn_fragment_count(256, 1));
}

/* --- M-10: f32le/f64le roundtrips --- */

static void test_wire_float_roundtrip(void)
{
    uint8_t buf[8];

    /* f32le roundtrip */
    float f = 3.14f;
    nn_write_f32le(buf, f);
    ASSERT("f32le_roundtrip", nn_read_f32le(buf) == f);

    /* f64le roundtrip */
    double d = 2.718281828459045;
    nn_write_f64le(buf, d);
    ASSERT("f64le_roundtrip", nn_read_f64le(buf) == d);

    /* Negative values */
    nn_write_f32le(buf, -1.5f);
    ASSERT("f32le_neg", nn_read_f32le(buf) == -1.5f);

    nn_write_f64le(buf, -1.5);
    ASSERT("f64le_neg", nn_read_f64le(buf) == -1.5);
}

/* --- M-10: nn_buf_has edge cases --- */

static void test_buf_has_edge_cases(void)
{
    /* Exact fit */
    ASSERT("buf_has_exact", nn_buf_has(10, 0, 10));
    /* One too many */
    ASSERT("buf_has_overshoot", !nn_buf_has(10, 0, 11));
    /* Offset at end */
    ASSERT("buf_has_end_1", !nn_buf_has(10, 10, 1));
    ASSERT("buf_has_end_0", nn_buf_has(10, 10, 0));
    /* Overflow: offset + need wraps around */
    ASSERT("buf_has_overflow", !nn_buf_has(10, SIZE_MAX, 1));
    ASSERT("buf_has_overflow2", !nn_buf_has(SIZE_MAX, 1, SIZE_MAX));
}

int main(void)
{
    test_fragment_header_roundtrip();
    test_fragment_header_truncated();
    test_fragment_header_invalid();
    test_fragment_count();
    test_fragment_build();
    test_batch_roundtrip();
    test_batch_overflow();
    test_batch_empty_buf();
    test_batch_single_message();
    test_fragment_write_validation();
    test_fragment_count_boundary();
    test_wire_float_roundtrip();
    test_buf_has_edge_cases();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
