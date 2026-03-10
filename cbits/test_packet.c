/*
 * test_packet.c — Verify nn_packet against gbnet-hs wire format
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -Icbits cbits/nn_packet.c cbits/test_packet.c -o test_packet
 * Run:   ./test_packet
 */

#include "nn_packet.h"
#include <stdio.h>
#include <string.h>

static int tests_run   = 0;
static int tests_passed = 0;

#define ASSERT_EQ(label, expected, actual) do {                         \
    tests_run++;                                                        \
    if ((expected) == (actual)) {                                        \
        tests_passed++;                                                 \
    } else {                                                            \
        printf("FAIL %s: expected %llu, got %llu\n",                    \
               (label),                                                 \
               (unsigned long long)(expected),                          \
               (unsigned long long)(actual));                           \
    }                                                                   \
} while (0)

static void test_roundtrip(const char *name, nn_packet_header hdr)
{
    uint8_t buf[NN_PACKET_HEADER_SIZE];
    nn_packet_header out;

    nn_packet_write(&hdr, buf);
    int rc = nn_packet_read(buf, NN_PACKET_HEADER_SIZE, &out);

    ASSERT_EQ(name, 0, rc);
    ASSERT_EQ(name, hdr.packet_type,  out.packet_type);
    ASSERT_EQ(name, hdr.sequence_num, out.sequence_num);
    ASSERT_EQ(name, hdr.ack,          out.ack);
    ASSERT_EQ(name, hdr.ack_bitfield, out.ack_bitfield);
}

static void test_payload_header(void)
{
    /* Same test vector as gbnet-hs: Payload, seq=42, ack=40, abf=0xDEADBEEF */
    nn_packet_header hdr = {
        .packet_type  = NN_PKT_PAYLOAD,
        .sequence_num = 42,
        .ack          = 40,
        .ack_bitfield = 0xDEADBEEF
    };
    test_roundtrip("payload", hdr);
}

static void test_connection_request(void)
{
    nn_packet_header hdr = {
        .packet_type  = NN_PKT_CONNECTION_REQUEST,
        .sequence_num = 0,
        .ack          = 0,
        .ack_bitfield = 0
    };
    test_roundtrip("conn_request", hdr);
}

static void test_keepalive(void)
{
    nn_packet_header hdr = {
        .packet_type  = NN_PKT_KEEPALIVE,
        .sequence_num = 1000,
        .ack          = 999,
        .ack_bitfield = 0xFFFFFFFF
    };
    test_roundtrip("keepalive", hdr);
}

static void test_disconnect(void)
{
    nn_packet_header hdr = {
        .packet_type  = NN_PKT_DISCONNECT,
        .sequence_num = 65535,
        .ack          = 65535,
        .ack_bitfield = 0xFFFFFFFF
    };
    test_roundtrip("disconnect_max", hdr);
}

static void test_all_types(void)
{
    for (uint8_t t = 0; t <= NN_PACKET_TYPE_MAX; t++) {
        char label[32];
        snprintf(label, sizeof(label), "type_%u", t);
        nn_packet_header hdr = {
            .packet_type  = t,
            .sequence_num = 12345,
            .ack          = 54321,
            .ack_bitfield = 0xABCD1234
        };
        test_roundtrip(label, hdr);
    }
}

static void test_boundary_values(void)
{
    /* Sequence number boundaries */
    nn_packet_header hdr_zero = {
        .packet_type = NN_PKT_PAYLOAD, .sequence_num = 0,
        .ack = 0, .ack_bitfield = 0
    };
    test_roundtrip("all_zero", hdr_zero);

    nn_packet_header hdr_max = {
        .packet_type = NN_PKT_CONNECTION_RESPONSE, .sequence_num = 0xFFFF,
        .ack = 0xFFFF, .ack_bitfield = 0xFFFFFFFF
    };
    test_roundtrip("all_max", hdr_max);

    /* Single bit in each field */
    nn_packet_header hdr_seq1 = {
        .packet_type = NN_PKT_PAYLOAD, .sequence_num = 1,
        .ack = 0, .ack_bitfield = 0
    };
    test_roundtrip("seq_1", hdr_seq1);

    nn_packet_header hdr_ack1 = {
        .packet_type = NN_PKT_PAYLOAD, .sequence_num = 0,
        .ack = 1, .ack_bitfield = 0
    };
    test_roundtrip("ack_1", hdr_ack1);

    nn_packet_header hdr_abf1 = {
        .packet_type = NN_PKT_PAYLOAD, .sequence_num = 0,
        .ack = 0, .ack_bitfield = 1
    };
    test_roundtrip("abf_1", hdr_abf1);

    /* High bits only */
    nn_packet_header hdr_seq_hi = {
        .packet_type = NN_PKT_PAYLOAD, .sequence_num = 0x8000,
        .ack = 0, .ack_bitfield = 0
    };
    test_roundtrip("seq_high_bit", hdr_seq_hi);

    nn_packet_header hdr_abf_hi = {
        .packet_type = NN_PKT_PAYLOAD, .sequence_num = 0,
        .ack = 0, .ack_bitfield = 0x80000000
    };
    test_roundtrip("abf_high_bit", hdr_abf_hi);
}

static void test_invalid_type(void)
{
    /* Craft a buffer with packet type = 8 (invalid) */
    uint8_t buf[NN_PACKET_HEADER_SIZE] = {0};
    buf[0] = 8 << 4; /* type 8 in high nibble */

    nn_packet_header out;
    int rc = nn_packet_read(buf, NN_PACKET_HEADER_SIZE, &out);

    tests_run++;
    if (rc == -1) {
        tests_passed++;
    } else {
        printf("FAIL invalid_type: expected -1, got %d\n", rc);
    }
}

static void test_truncated(void)
{
    uint8_t buf[4] = {0};
    nn_packet_header out;
    int rc = nn_packet_read(buf, 4, &out);

    tests_run++;
    if (rc == -1) {
        tests_passed++;
    } else {
        printf("FAIL truncated: expected -1, got %d\n", rc);
    }
}

int main(void)
{
    test_payload_header();
    test_connection_request();
    test_keepalive();
    test_disconnect();
    test_all_types();
    test_boundary_values();
    test_invalid_type();
    test_truncated();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
