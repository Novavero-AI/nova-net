/*
 * test_crc32c.c — Verify CRC32C against known test vectors
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -march=native -Icbits cbits/nn_crc32c.c cbits/test_crc32c.c -o test_crc32c
 */

#include "nn_crc32c.h"
#include <stdio.h>
#include <string.h>

static int tests_run = 0;
static int tests_passed = 0;

#define ASSERT_EQ(label, expected, actual) do {                         \
    tests_run++;                                                        \
    if ((expected) == (actual)) {                                        \
        tests_passed++;                                                 \
    } else {                                                            \
        printf("FAIL %s: expected 0x%08X, got 0x%08X\n",               \
               (label), (unsigned)(expected), (unsigned)(actual));       \
    }                                                                   \
} while (0)

static void test_known_vectors(void)
{
    /* RFC 3720 / iSCSI test vectors for CRC32C */

    /* Empty input */
    ASSERT_EQ("empty", 0x00000000, nn_crc32c(NULL, 0));

    /* "123456789" → 0xE3069283 */
    const uint8_t digits[] = "123456789";
    ASSERT_EQ("digits", 0xE3069283, nn_crc32c(digits, 9));

    /* 32 bytes of zeros */
    uint8_t zeros[32];
    memset(zeros, 0, sizeof(zeros));
    ASSERT_EQ("32_zeros", 0x8A9136AA, nn_crc32c(zeros, 32));

    /* 32 bytes of 0xFF */
    uint8_t ones[32];
    memset(ones, 0xFF, sizeof(ones));
    ASSERT_EQ("32_ones", 0x62A8AB43, nn_crc32c(ones, 32));

    /* Single byte: 0x00 */
    uint8_t single_zero = 0x00;
    ASSERT_EQ("single_zero", 0x527D5351, nn_crc32c(&single_zero, 1));

    /* Ascending 32 bytes: 0x00..0x1F → 0x46DD794E */
    uint8_t ascending[32];
    for (int i = 0; i < 32; i++) ascending[i] = (uint8_t)i;
    ASSERT_EQ("ascending", 0x46DD794E, nn_crc32c(ascending, 32));
}

static void test_append_validate(void)
{
    uint8_t buf[128];
    const char *msg = "hello nova-net";
    size_t msg_len = strlen(msg);

    memcpy(buf, msg, msg_len);

    /* Append CRC */
    size_t total = nn_crc32c_append(buf, msg_len);
    tests_run++;
    if (total == msg_len + NN_CRC32C_SIZE) {
        tests_passed++;
    } else {
        printf("FAIL append_len: expected %zu, got %zu\n",
               msg_len + NN_CRC32C_SIZE, total);
    }

    /* Validate succeeds */
    size_t payload_len = nn_crc32c_validate(buf, total);
    tests_run++;
    if (payload_len == msg_len) {
        tests_passed++;
    } else {
        printf("FAIL validate_ok: expected %zu, got %zu\n", msg_len, payload_len);
    }

    /* Corrupt one byte → validate fails */
    buf[3] ^= 0x01;
    size_t corrupt_len = nn_crc32c_validate(buf, total);
    tests_run++;
    if (corrupt_len == 0) {
        tests_passed++;
    } else {
        printf("FAIL validate_corrupt: expected 0, got %zu\n", corrupt_len);
    }

    /* Too short → validate fails */
    size_t short_len = nn_crc32c_validate(buf, 3);
    tests_run++;
    if (short_len == 0) {
        tests_passed++;
    } else {
        printf("FAIL validate_short: expected 0, got %zu\n", short_len);
    }
}

static void test_various_lengths(void)
{
    /* Test 1-64 byte inputs don't crash and produce consistent results */
    uint8_t buf[128];
    for (size_t len = 1; len <= 64; len++) {
        for (size_t i = 0; i < len; i++) buf[i] = (uint8_t)(i * 7 + len);

        uint32_t crc1 = nn_crc32c(buf, len);
        uint32_t crc2 = nn_crc32c(buf, len);

        tests_run++;
        if (crc1 == crc2) {
            tests_passed++;
        } else {
            printf("FAIL consistency_len_%zu: %08X != %08X\n", len, crc1, crc2);
        }
    }
}

int main(void)
{
    test_known_vectors();
    test_append_validate();
    test_various_lengths();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
