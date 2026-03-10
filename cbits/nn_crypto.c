/*
 * nn_crypto.c — ChaCha20-Poly1305 AEAD (RFC 8439)
 *
 * Self-contained. No external crypto libraries.
 *
 * ChaCha20:    RFC 8439 Section 2.3 (quarter-round, block function)
 * Poly1305:    RFC 8439 Section 2.5 (one-time authenticator)
 * AEAD:        RFC 8439 Section 2.8 (construction)
 */

#include "nn_crypto.h"
#include "nn_wire.h"
#include <string.h>

/* ---------------------------------------------------------------------------
 * ChaCha20 quarter-round (RFC 8439 Section 2.1)
 * ------------------------------------------------------------------------- */

#define ROTL32(v, n) (((v) << (n)) | ((v) >> (32 - (n))))

#define QR(a, b, c, d)                  \
    do {                                \
        a += b; d ^= a; d = ROTL32(d, 16); \
        c += d; b ^= c; b = ROTL32(b, 12); \
        a += b; d ^= a; d = ROTL32(d, 8);  \
        c += d; b ^= c; b = ROTL32(b, 7);  \
    } while (0)

/* ---------------------------------------------------------------------------
 * ChaCha20 block function (RFC 8439 Section 2.3)
 *
 * state: 16 x uint32_t (key setup already done)
 * out:   64 bytes of keystream
 * ------------------------------------------------------------------------- */

static void
chacha20_block(const uint32_t state[16], uint8_t out[NN_CHACHA20_BLOCK_SIZE])
{
    uint32_t x[16];
    memcpy(x, state, sizeof(x));

    /* 20 rounds (10 double-rounds) */
    for (int i = 0; i < 10; i++) {
        /* Column rounds */
        QR(x[0], x[4], x[ 8], x[12]);
        QR(x[1], x[5], x[ 9], x[13]);
        QR(x[2], x[6], x[10], x[14]);
        QR(x[3], x[7], x[11], x[15]);
        /* Diagonal rounds */
        QR(x[0], x[5], x[10], x[15]);
        QR(x[1], x[6], x[11], x[12]);
        QR(x[2], x[7], x[ 8], x[13]);
        QR(x[3], x[4], x[ 9], x[14]);
    }

    /* Add original state */
    for (int i = 0; i < 16; i++)
        x[i] += state[i];

    /* Serialize to little-endian bytes */
    for (int i = 0; i < 16; i++)
        nn_write_u32le(out + i * 4, x[i]);
}

/* ---------------------------------------------------------------------------
 * ChaCha20 key setup
 *
 * "expand 32-byte k" constant + key + counter + nonce
 * ------------------------------------------------------------------------- */

static const uint32_t chacha20_constants[4] = {
    0x61707865, 0x3320646E, 0x79622D32, 0x6B206574
};

static void
chacha20_setup(uint32_t state[16], const uint8_t key[NN_CRYPTO_KEY_SIZE],
               uint32_t counter, const uint8_t nonce[NN_CHACHA20_NONCE_SIZE])
{
    state[0]  = chacha20_constants[0];
    state[1]  = chacha20_constants[1];
    state[2]  = chacha20_constants[2];
    state[3]  = chacha20_constants[3];
    state[4]  = nn_read_u32le(key +  0);
    state[5]  = nn_read_u32le(key +  4);
    state[6]  = nn_read_u32le(key +  8);
    state[7]  = nn_read_u32le(key + 12);
    state[8]  = nn_read_u32le(key + 16);
    state[9]  = nn_read_u32le(key + 20);
    state[10] = nn_read_u32le(key + 24);
    state[11] = nn_read_u32le(key + 28);
    state[12] = counter;
    state[13] = nn_read_u32le(nonce + 0);
    state[14] = nn_read_u32le(nonce + 4);
    state[15] = nn_read_u32le(nonce + 8);
}

/* ---------------------------------------------------------------------------
 * ChaCha20 encrypt/decrypt (XOR with keystream)
 * ------------------------------------------------------------------------- */

static void
chacha20_crypt(const uint8_t key[NN_CRYPTO_KEY_SIZE],
               const uint8_t nonce[NN_CHACHA20_NONCE_SIZE],
               uint32_t initial_counter,
               uint8_t *data, size_t len)
{
    uint32_t state[16];
    uint8_t block[NN_CHACHA20_BLOCK_SIZE];
    uint32_t counter = initial_counter;

    while (len > 0) {
        chacha20_setup(state, key, counter, nonce);
        chacha20_block(state, block);
        counter++;

        size_t chunk = len < NN_CHACHA20_BLOCK_SIZE ? len : NN_CHACHA20_BLOCK_SIZE;
        for (size_t i = 0; i < chunk; i++)
            data[i] ^= block[i];

        data += chunk;
        len  -= chunk;
    }

    /* Wipe keystream from stack */
    memset(block, 0, sizeof(block));
    memset(state, 0, sizeof(state));
}

/* ---------------------------------------------------------------------------
 * Poly1305 MAC (RFC 8439 Section 2.5)
 *
 * Uses 130-bit arithmetic via 5 x 26-bit limbs. No heap, no bignum library.
 * Based on the reference algorithm from RFC 8439 / DJB's poly1305-donna.
 * ------------------------------------------------------------------------- */

typedef struct {
    uint32_t r[5];   /* clamped key r in 26-bit limbs */
    uint32_t h[5];   /* accumulator h in 26-bit limbs */
    uint32_t pad[4]; /* one-time pad s (from key bytes 16-31) */
} poly1305_state;

static void
poly1305_init(poly1305_state *st, const uint8_t key[32])
{
    /* r = key[0..15] with clamping */
    uint32_t t0 = nn_read_u32le(key +  0);
    uint32_t t1 = nn_read_u32le(key +  4);
    uint32_t t2 = nn_read_u32le(key +  8);
    uint32_t t3 = nn_read_u32le(key + 12);

    st->r[0] =  t0                         & 0x3FFFFFF;
    st->r[1] = ((t0 >> 26) | (t1 <<  6))  & 0x3FFFF03;
    st->r[2] = ((t1 >> 20) | (t2 << 12))  & 0x3FFC0FF;
    st->r[3] = ((t2 >> 14) | (t3 << 18))  & 0x3F03FFF;
    st->r[4] =  (t3 >>  8)                 & 0x00FFFFF;

    /* h = 0 */
    st->h[0] = st->h[1] = st->h[2] = st->h[3] = st->h[4] = 0;

    /* pad = key[16..31] */
    st->pad[0] = nn_read_u32le(key + 16);
    st->pad[1] = nn_read_u32le(key + 20);
    st->pad[2] = nn_read_u32le(key + 24);
    st->pad[3] = nn_read_u32le(key + 28);
}

static void
poly1305_blocks(poly1305_state *st, const uint8_t *data, size_t len, int final_block)
{
    const uint32_t hibit = final_block ? 0 : (1u << 24);

    while (len >= 16) {
        /* h += msg */
        uint32_t t0 = nn_read_u32le(data +  0);
        uint32_t t1 = nn_read_u32le(data +  4);
        uint32_t t2 = nn_read_u32le(data +  8);
        uint32_t t3 = nn_read_u32le(data + 12);

        st->h[0] += t0 & 0x3FFFFFF;
        st->h[1] += ((t0 >> 26) | (t1 <<  6)) & 0x3FFFFFF;
        st->h[2] += ((t1 >> 20) | (t2 << 12)) & 0x3FFFFFF;
        st->h[3] += ((t2 >> 14) | (t3 << 18)) & 0x3FFFFFF;
        st->h[4] += (t3 >> 8) | hibit;

        /* h *= r (mod 2^130 - 5) */
        uint64_t r0 = st->r[0], r1 = st->r[1], r2 = st->r[2];
        uint64_t r3 = st->r[3], r4 = st->r[4];
        uint64_t s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;

        uint64_t d0 = (uint64_t)st->h[0]*r0 + (uint64_t)st->h[1]*s4 +
                      (uint64_t)st->h[2]*s3 + (uint64_t)st->h[3]*s2 +
                      (uint64_t)st->h[4]*s1;
        uint64_t d1 = (uint64_t)st->h[0]*r1 + (uint64_t)st->h[1]*r0 +
                      (uint64_t)st->h[2]*s4 + (uint64_t)st->h[3]*s3 +
                      (uint64_t)st->h[4]*s2;
        uint64_t d2 = (uint64_t)st->h[0]*r2 + (uint64_t)st->h[1]*r1 +
                      (uint64_t)st->h[2]*r0 + (uint64_t)st->h[3]*s4 +
                      (uint64_t)st->h[4]*s3;
        uint64_t d3 = (uint64_t)st->h[0]*r3 + (uint64_t)st->h[1]*r2 +
                      (uint64_t)st->h[2]*r1 + (uint64_t)st->h[3]*r0 +
                      (uint64_t)st->h[4]*s4;
        uint64_t d4 = (uint64_t)st->h[0]*r4 + (uint64_t)st->h[1]*r3 +
                      (uint64_t)st->h[2]*r2 + (uint64_t)st->h[3]*r1 +
                      (uint64_t)st->h[4]*r0;

        /* Carry propagation */
        uint32_t c;
        c = (uint32_t)(d0 >> 26); st->h[0] = (uint32_t)d0 & 0x3FFFFFF; d1 += c;
        c = (uint32_t)(d1 >> 26); st->h[1] = (uint32_t)d1 & 0x3FFFFFF; d2 += c;
        c = (uint32_t)(d2 >> 26); st->h[2] = (uint32_t)d2 & 0x3FFFFFF; d3 += c;
        c = (uint32_t)(d3 >> 26); st->h[3] = (uint32_t)d3 & 0x3FFFFFF; d4 += c;
        c = (uint32_t)(d4 >> 26); st->h[4] = (uint32_t)d4 & 0x3FFFFFF;
        st->h[0] += c * 5;
        c = st->h[0] >> 26; st->h[0] &= 0x3FFFFFF;
        st->h[1] += c;

        data += 16;
        len  -= 16;
    }
}

static void
poly1305_finish(poly1305_state *st, const uint8_t *data, size_t remaining,
                uint8_t tag[NN_CRYPTO_TAG_SIZE])
{
    /* Process remaining bytes (< 16) with padding */
    if (remaining > 0) {
        uint8_t block[16];
        memset(block, 0, sizeof(block));
        memcpy(block, data, remaining);
        block[remaining] = 1; /* padding bit */
        poly1305_blocks(st, block, 16, 1);
    }

    /* Full carry chain */
    uint32_t c;
    c = st->h[1] >> 26; st->h[1] &= 0x3FFFFFF; st->h[2] += c;
    c = st->h[2] >> 26; st->h[2] &= 0x3FFFFFF; st->h[3] += c;
    c = st->h[3] >> 26; st->h[3] &= 0x3FFFFFF; st->h[4] += c;
    c = st->h[4] >> 26; st->h[4] &= 0x3FFFFFF; st->h[0] += c * 5;
    c = st->h[0] >> 26; st->h[0] &= 0x3FFFFFF; st->h[1] += c;

    /* Compute h - p (where p = 2^130 - 5) */
    uint32_t g0 = st->h[0] + 5; c = g0 >> 26; g0 &= 0x3FFFFFF;
    uint32_t g1 = st->h[1] + c; c = g1 >> 26; g1 &= 0x3FFFFFF;
    uint32_t g2 = st->h[2] + c; c = g2 >> 26; g2 &= 0x3FFFFFF;
    uint32_t g3 = st->h[3] + c; c = g3 >> 26; g3 &= 0x3FFFFFF;
    uint32_t g4 = st->h[4] + c - (1u << 26);

    /* Select h or h-p based on carry */
    uint32_t mask = (g4 >> 31) - 1; /* 0xFFFFFFFF if g4 >= 0, 0 otherwise */
    g0 &= mask; g1 &= mask; g2 &= mask; g3 &= mask; g4 &= mask;
    mask = ~mask;
    st->h[0] = (st->h[0] & mask) | g0;
    st->h[1] = (st->h[1] & mask) | g1;
    st->h[2] = (st->h[2] & mask) | g2;
    st->h[3] = (st->h[3] & mask) | g3;
    st->h[4] = (st->h[4] & mask) | g4;

    /* h = h + pad (mod 2^128) */
    uint64_t f;
    f  = (uint64_t)st->h[0] | ((uint64_t)st->h[1] << 26);
    f += st->pad[0];
    nn_write_u32le(tag + 0, (uint32_t)f); f >>= 32;

    f += (uint64_t)st->h[1] >> 6 | ((uint64_t)st->h[2] << 20);
    f += st->pad[1];
    nn_write_u32le(tag + 4, (uint32_t)f); f >>= 32;

    f += (uint64_t)st->h[2] >> 12 | ((uint64_t)st->h[3] << 14);
    f += st->pad[2];
    nn_write_u32le(tag + 8, (uint32_t)f); f >>= 32;

    f += (uint64_t)st->h[3] >> 18 | ((uint64_t)st->h[4] << 8);
    f += st->pad[3];
    nn_write_u32le(tag + 12, (uint32_t)f);

    /* Wipe state */
    memset(st, 0, sizeof(*st));
}

/* ---------------------------------------------------------------------------
 * AEAD construction (RFC 8439 Section 2.8)
 *
 * 1. Generate Poly1305 one-time key from ChaCha20 block 0
 * 2. Encrypt with ChaCha20 starting at block 1
 * 3. Construct MAC input: AAD || pad || ciphertext || pad || lengths
 * 4. Compute Poly1305 tag
 * ------------------------------------------------------------------------- */

/**
 * Build the nonce from counter + protocol_id.
 * Nova-net format: [counter:8 LE][protocol_id:4 LE] = 12 bytes
 */
static void
build_nonce(uint64_t counter, uint32_t protocol_id,
            uint8_t nonce[NN_CHACHA20_NONCE_SIZE])
{
    nn_write_u64le(nonce, counter);
    nn_write_u32le(nonce + 8, protocol_id);
}

int
nn_crypto_encrypt(const uint8_t *key, uint64_t counter,
                  uint32_t protocol_id,
                  uint8_t *buf, size_t plain_len)
{
    uint8_t nonce[NN_CHACHA20_NONCE_SIZE];
    build_nonce(counter, protocol_id, nonce);

    /* Write nonce counter to wire (first 8 bytes of buf) */
    nn_write_u64le(buf, counter);

    uint8_t *plaintext = buf + NN_CRYPTO_NONCE_SIZE;

    /* Step 1: Generate Poly1305 one-time key from ChaCha20 block 0 */
    uint32_t state[16];
    uint8_t poly_key_block[NN_CHACHA20_BLOCK_SIZE];
    chacha20_setup(state, key, 0, nonce);
    chacha20_block(state, poly_key_block);
    /* First 32 bytes are the Poly1305 key */

    /* Step 2: Encrypt with ChaCha20 starting at counter=1 */
    chacha20_crypt(key, nonce, 1, plaintext, plain_len);

    /* Step 3+4: Compute Poly1305 tag over (AAD || pad || ciphertext || pad || lengths)
     * We use no AAD, so: pad(0) || ciphertext || pad(ciphertext) || lengths */

    /* Build MAC input on stack */
    /* For no-AAD case: ciphertext || pad16(ct_len) || le64(0) || le64(ct_len) */
    poly1305_state pst;
    poly1305_init(&pst, poly_key_block);

    /* Process ciphertext blocks */
    size_t full = plain_len & ~15u;
    if (full > 0)
        poly1305_blocks(&pst, plaintext, full, 0);

    /* Remaining ciphertext + padding to 16 */
    size_t rem = plain_len - full;
    uint8_t last_block[16];
    memset(last_block, 0, sizeof(last_block));
    if (rem > 0)
        memcpy(last_block, plaintext + full, rem);

    if (rem > 0)
        poly1305_blocks(&pst, last_block, 16, 0);

    /* Lengths block: le64(aad_len=0) || le64(ciphertext_len) */
    uint8_t lengths[16];
    nn_write_u64le(lengths, 0);
    nn_write_u64le(lengths + 8, (uint64_t)plain_len);
    /* Process lengths as final block (with hibit) — actually, RFC 8439
       says all MAC data blocks use the normal accumulate. The "final" only
       applies to the last partial block of the actual message. For the
       lengths block which is always exactly 16 bytes, use normal. */
    poly1305_blocks(&pst, lengths, 16, 0);

    /* Finalize — no remaining bytes */
    uint8_t *tag = plaintext + plain_len;
    poly1305_finish(&pst, NULL, 0, tag);

    /* Wipe sensitive data */
    memset(poly_key_block, 0, sizeof(poly_key_block));
    memset(state, 0, sizeof(state));

    return (int)(NN_CRYPTO_NONCE_SIZE + plain_len + NN_CRYPTO_TAG_SIZE);
}

int
nn_crypto_decrypt(const uint8_t *key, uint32_t protocol_id,
                  uint8_t *buf, size_t total_len,
                  uint64_t *out_counter, size_t *out_plain_len)
{
    if (total_len < NN_CRYPTO_OVERHEAD)
        return NN_CRYPTO_ERR_SHORT;

    /* Extract counter from wire */
    uint64_t counter = nn_read_u64le(buf);
    *out_counter = counter;

    uint8_t nonce[NN_CHACHA20_NONCE_SIZE];
    build_nonce(counter, protocol_id, nonce);

    size_t cipher_len = total_len - NN_CRYPTO_NONCE_SIZE - NN_CRYPTO_TAG_SIZE;
    uint8_t *ciphertext = buf + NN_CRYPTO_NONCE_SIZE;
    const uint8_t *recv_tag = ciphertext + cipher_len;

    /* Step 1: Generate Poly1305 one-time key */
    uint32_t state[16];
    uint8_t poly_key_block[NN_CHACHA20_BLOCK_SIZE];
    chacha20_setup(state, key, 0, nonce);
    chacha20_block(state, poly_key_block);

    /* Step 2: Verify tag BEFORE decrypting (authenticate-then-decrypt) */
    poly1305_state pst;
    poly1305_init(&pst, poly_key_block);

    size_t full = cipher_len & ~15u;
    if (full > 0)
        poly1305_blocks(&pst, ciphertext, full, 0);

    size_t rem = cipher_len - full;
    uint8_t last_block[16];
    memset(last_block, 0, sizeof(last_block));
    if (rem > 0) {
        memcpy(last_block, ciphertext + full, rem);
        poly1305_blocks(&pst, last_block, 16, 0);
    }

    uint8_t lengths[16];
    nn_write_u64le(lengths, 0);
    nn_write_u64le(lengths + 8, (uint64_t)cipher_len);
    poly1305_blocks(&pst, lengths, 16, 0);

    uint8_t computed_tag[NN_CRYPTO_TAG_SIZE];
    poly1305_finish(&pst, NULL, 0, computed_tag);

    /* Constant-time comparison */
    uint8_t diff = 0;
    for (int i = 0; i < NN_CRYPTO_TAG_SIZE; i++)
        diff |= computed_tag[i] ^ recv_tag[i];

    memset(poly_key_block, 0, sizeof(poly_key_block));
    memset(state, 0, sizeof(state));

    if (diff != 0)
        return NN_CRYPTO_ERR_AUTH;

    /* Step 3: Decrypt (counter=1) */
    chacha20_crypt(key, nonce, 1, ciphertext, cipher_len);

    *out_plain_len = cipher_len;
    return NN_CRYPTO_OK;
}
