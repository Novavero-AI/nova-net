/*
 * test_crypto.c — Verify ChaCha20-Poly1305 AEAD
 *
 * Build: cc -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 -Icbits \
 *        cbits/nn_crypto.c cbits/test_crypto.c -o test_crypto
 */

#include "nn_crypto.h"
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
    else { printf("FAIL %s: expected %d, got %d\n", (label),            \
           (int)(expected), (int)(actual)); }                           \
} while (0)

/* --- Basic encrypt/decrypt roundtrip --- */

static void test_roundtrip_64(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0xAA, sizeof(key));

    uint8_t buf[NN_CRYPTO_NONCE_SIZE + 64 + NN_CRYPTO_TAG_SIZE];
    uint8_t original[64];
    for (int i = 0; i < 64; i++) original[i] = (uint8_t)i;

    /* Place plaintext after nonce slot */
    memcpy(buf + NN_CRYPTO_NONCE_SIZE, original, 64);

    int enc_len = nn_crypto_encrypt(key, 42, 0x12345678, buf, 64);
    ASSERT("enc64_len", enc_len == NN_CRYPTO_NONCE_SIZE + 64 + NN_CRYPTO_TAG_SIZE);

    /* Ciphertext should differ from plaintext */
    ASSERT("enc64_changed", memcmp(buf + NN_CRYPTO_NONCE_SIZE, original, 64) != 0);

    /* Decrypt */
    uint64_t counter;
    size_t plain_len;
    int rc = nn_crypto_decrypt(key, 0x12345678, buf, (size_t)enc_len, &counter, &plain_len);
    ASSERT_EQ("dec64_ok", NN_CRYPTO_OK, rc);
    ASSERT_EQ("dec64_counter", 42, (int)counter);
    ASSERT_EQ("dec64_len", 64, (int)plain_len);
    ASSERT("dec64_match", memcmp(buf + NN_CRYPTO_NONCE_SIZE, original, 64) == 0);
}

static void test_roundtrip_1k(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0xBB, sizeof(key));

    uint8_t buf[NN_CRYPTO_NONCE_SIZE + 1024 + NN_CRYPTO_TAG_SIZE];
    uint8_t original[1024];
    for (int i = 0; i < 1024; i++) original[i] = (uint8_t)(i * 7);

    memcpy(buf + NN_CRYPTO_NONCE_SIZE, original, 1024);

    int enc_len = nn_crypto_encrypt(key, 100, 0xDEADBEEF, buf, 1024);
    ASSERT("enc1k_len", enc_len > 0);

    uint64_t counter;
    size_t plain_len;
    int rc = nn_crypto_decrypt(key, 0xDEADBEEF, buf, (size_t)enc_len, &counter, &plain_len);
    ASSERT_EQ("dec1k_ok", NN_CRYPTO_OK, rc);
    ASSERT_EQ("dec1k_len", 1024, (int)plain_len);
    ASSERT("dec1k_match", memcmp(buf + NN_CRYPTO_NONCE_SIZE, original, 1024) == 0);
}

/* --- Wrong key → auth error --- */

static void test_wrong_key(void)
{
    uint8_t key1[NN_CRYPTO_KEY_SIZE], key2[NN_CRYPTO_KEY_SIZE];
    memset(key1, 0xAA, sizeof(key1));
    memset(key2, 0xBB, sizeof(key2));

    uint8_t buf[NN_CRYPTO_NONCE_SIZE + 32 + NN_CRYPTO_TAG_SIZE];
    memset(buf + NN_CRYPTO_NONCE_SIZE, 0xCD, 32);

    nn_crypto_encrypt(key1, 1, 0x11111111, buf, 32);

    uint64_t counter;
    size_t plain_len;
    int rc = nn_crypto_decrypt(key2, 0x11111111, buf, sizeof(buf), &counter, &plain_len);
    ASSERT_EQ("wrong_key", NN_CRYPTO_ERR_AUTH, rc);
}

/* --- Tampered ciphertext → auth error --- */

static void test_tampered(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0xCC, sizeof(key));

    uint8_t buf[NN_CRYPTO_NONCE_SIZE + 48 + NN_CRYPTO_TAG_SIZE];
    memset(buf + NN_CRYPTO_NONCE_SIZE, 0xEE, 48);

    int enc_len = nn_crypto_encrypt(key, 5, 0x22222222, buf, 48);

    /* Flip a bit in the ciphertext */
    buf[NN_CRYPTO_NONCE_SIZE + 10] ^= 0x01;

    uint64_t counter;
    size_t plain_len;
    int rc = nn_crypto_decrypt(key, 0x22222222, buf, (size_t)enc_len, &counter, &plain_len);
    ASSERT_EQ("tampered", NN_CRYPTO_ERR_AUTH, rc);
}

/* --- Too short → error --- */

static void test_too_short(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0, sizeof(key));

    uint8_t buf[10];
    uint64_t counter;
    size_t plain_len;
    int rc = nn_crypto_decrypt(key, 0, buf, 10, &counter, &plain_len);
    ASSERT_EQ("too_short", NN_CRYPTO_ERR_SHORT, rc);
}

/* --- Nonce counter preserved --- */

static void test_nonce_counter(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0xDD, sizeof(key));

    uint8_t buf[NN_CRYPTO_NONCE_SIZE + 16 + NN_CRYPTO_TAG_SIZE];
    memset(buf + NN_CRYPTO_NONCE_SIZE, 0xFF, 16);

    nn_crypto_encrypt(key, 9999, 0x33333333, buf, 16);

    /* Verify nonce counter on wire (first 8 bytes, LE) */
    uint64_t wire_counter = nn_read_u64le(buf);
    ASSERT_EQ("nonce_wire", 9999, (int)wire_counter);

    /* Decrypt and check counter */
    uint64_t counter;
    size_t plain_len;
    nn_crypto_decrypt(key, 0x33333333, buf, sizeof(buf), &counter, &plain_len);
    ASSERT_EQ("nonce_dec", 9999, (int)counter);
}

/* --- Empty plaintext --- */

static void test_empty_plaintext(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0xEE, sizeof(key));

    uint8_t buf[NN_CRYPTO_NONCE_SIZE + 0 + NN_CRYPTO_TAG_SIZE];

    int enc_len = nn_crypto_encrypt(key, 1, 0x44444444, buf, 0);
    ASSERT_EQ("empty_enc_len", (int)NN_CRYPTO_OVERHEAD, enc_len);

    uint64_t counter;
    size_t plain_len;
    int rc = nn_crypto_decrypt(key, 0x44444444, buf, (size_t)enc_len, &counter, &plain_len);
    ASSERT_EQ("empty_dec_ok", NN_CRYPTO_OK, rc);
    ASSERT_EQ("empty_dec_len", 0, (int)plain_len);
}

/* --- Different counters produce different ciphertexts --- */

static void test_different_counters(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0x11, sizeof(key));

    uint8_t buf1[NN_CRYPTO_NONCE_SIZE + 32 + NN_CRYPTO_TAG_SIZE];
    uint8_t buf2[NN_CRYPTO_NONCE_SIZE + 32 + NN_CRYPTO_TAG_SIZE];

    memset(buf1 + NN_CRYPTO_NONCE_SIZE, 0xAB, 32);
    memset(buf2 + NN_CRYPTO_NONCE_SIZE, 0xAB, 32);

    nn_crypto_encrypt(key, 1, 0x55555555, buf1, 32);
    nn_crypto_encrypt(key, 2, 0x55555555, buf2, 32);

    /* Ciphertexts should differ (different nonces) */
    ASSERT("diff_counters", memcmp(buf1 + NN_CRYPTO_NONCE_SIZE,
                                    buf2 + NN_CRYPTO_NONCE_SIZE, 32) != 0);
}

/* --- Various payload sizes (test block boundary handling) --- */

static void test_various_sizes(void)
{
    uint8_t key[NN_CRYPTO_KEY_SIZE];
    memset(key, 0x77, sizeof(key));

    /* Test sizes that exercise block boundaries: 1, 15, 16, 17, 63, 64, 65, 127, 128 */
    size_t sizes[] = {1, 15, 16, 17, 63, 64, 65, 127, 128, 200};
    int num_sizes = (int)(sizeof(sizes) / sizeof(sizes[0]));

    for (int s = 0; s < num_sizes; s++) {
        size_t sz = sizes[s];
        uint8_t buf[NN_CRYPTO_NONCE_SIZE + 200 + NN_CRYPTO_TAG_SIZE];
        uint8_t original[200];

        for (size_t i = 0; i < sz; i++)
            original[i] = (uint8_t)(i * 13 + s);
        memcpy(buf + NN_CRYPTO_NONCE_SIZE, original, sz);

        int enc_len = nn_crypto_encrypt(key, (uint64_t)s, 0x88888888, buf, sz);
        ASSERT("var_enc", enc_len > 0);

        uint64_t counter;
        size_t plain_len;
        int rc = nn_crypto_decrypt(key, 0x88888888, buf, (size_t)enc_len,
                                   &counter, &plain_len);

        char label[64];
        snprintf(label, sizeof(label), "var_sz_%zu_rc", sz);
        ASSERT_EQ(label, NN_CRYPTO_OK, rc);

        snprintf(label, sizeof(label), "var_sz_%zu_len", sz);
        ASSERT_EQ(label, (int)sz, (int)plain_len);

        snprintf(label, sizeof(label), "var_sz_%zu_match", sz);
        ASSERT(label, memcmp(buf + NN_CRYPTO_NONCE_SIZE, original, sz) == 0);
    }
}

int main(void)
{
    test_roundtrip_64();
    test_roundtrip_1k();
    test_wrong_key();
    test_tampered();
    test_too_short();
    test_nonce_counter();
    test_empty_plaintext();
    test_different_counters();
    test_various_sizes();

    printf("%d/%d tests passed\n", tests_passed, tests_run);
    return tests_passed == tests_run ? 0 : 1;
}
