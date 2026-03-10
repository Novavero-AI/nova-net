/*
 * nn_crc32c.c — CRC32C (Castagnoli) with hardware acceleration
 *
 * Three implementations, selected at compile time:
 *   1. x86_64 SSE4.2: _mm_crc32_u8 / _mm_crc32_u64
 *   2. aarch64 ARMv8 CRC: __crc32cb / __crc32cd
 *   3. Software fallback: slice-by-4 table lookup
 */

#include "nn_crc32c.h"
#include "nn_wire.h"

/* ---------------------------------------------------------------------------
 * Implementation selection
 * ------------------------------------------------------------------------- */

#if defined(__x86_64__) && defined(__SSE4_2__)
  #define NN_CRC32C_X86 1
  #include <nmmintrin.h>
#elif defined(__aarch64__) && defined(__ARM_FEATURE_CRC32)
  #define NN_CRC32C_ARM 1
  #include <arm_acle.h>
#else
  #define NN_CRC32C_SW 1
#endif

/* ---------------------------------------------------------------------------
 * Software fallback — lookup table
 *
 * CRC32C (Castagnoli) polynomial: 0x1EDC6F41 (normal), 0x82F63B78 (reflected)
 * RFC 3720 Section 12.1, Castagnoli et al. 1993
 *
 * Generated from:
 *   for (i = 0; i < 256; i++) {
 *       crc = i;
 *       for (j = 0; j < 8; j++)
 *           crc = (crc >> 1) ^ ((crc & 1) ? 0x82F63B78 : 0);
 *       table[i] = crc;
 *   }
 * ------------------------------------------------------------------------- */

#ifdef NN_CRC32C_SW

static const uint32_t crc32c_table[256] = {
    0x00000000, 0xF26B8303, 0xE13B70F7, 0x1350F3F4,
    0xC79A971F, 0x35F1141C, 0x26A1E7E8, 0xD4CA64EB,
    0x8AD958CF, 0x78B2DBCC, 0x6BE22838, 0x9989AB3B,
    0x4D43CFD0, 0xBF284CD3, 0xAC78BF27, 0x5E133C24,
    0x105EC76F, 0xE235446C, 0xF165B798, 0x030E349B,
    0xD7C45070, 0x25AFD373, 0x36FF2087, 0xC494A384,
    0x9A879FA0, 0x68EC1CA3, 0x7BBCEF57, 0x89D76C54,
    0x5D1D08BF, 0xAF768BBC, 0xBC267848, 0x4E4DFB4B,
    0x20BD8EDE, 0xD2D60DDD, 0xC186FE29, 0x33ED7D2A,
    0xE72719C1, 0x154C9AC2, 0x061C6936, 0xF477EA35,
    0xAA64D611, 0x580F5512, 0x4B5FA6E6, 0xB93425E5,
    0x6DFE410E, 0x9F95C20D, 0x8CC531F9, 0x7EAEB2FA,
    0x30E349B1, 0xC288CAB2, 0xD1D83946, 0x23B3BA45,
    0xF779DEAE, 0x05125DAD, 0x1642AE59, 0xE4292D5A,
    0xBA3A117E, 0x4851927D, 0x5B016189, 0xA96AE28A,
    0x7DA08661, 0x8FCB0562, 0x9C9BF696, 0x6EF07595,
    0x417B1DBC, 0xB3109EBF, 0xA0406D4B, 0x522BEE48,
    0x86E18AA3, 0x748A09A0, 0x67DAFA54, 0x95B17957,
    0xCBA24573, 0x39C9C670, 0x2A993584, 0xD8F2B687,
    0x0C38D26C, 0xFE53516F, 0xED03A29B, 0x1F682198,
    0x5125DAD3, 0xA34E59D0, 0xB01EAA24, 0x42752927,
    0x96BF4DCC, 0x64D4CECF, 0x77843D3B, 0x85EFBE38,
    0xDBFC821C, 0x2997011F, 0x3AC7F2EB, 0xC8AC71E8,
    0x1C661503, 0xEE0D9600, 0xFD5D65F4, 0x0F36E6F7,
    0x61C69362, 0x93AD1061, 0x80FDE395, 0x72966096,
    0xA65C047D, 0x5437877E, 0x4767748A, 0xB50CF789,
    0xEB1FCBAD, 0x197448AE, 0x0A24BB5A, 0xF84F3859,
    0x2C855CB2, 0xDEEEDFB1, 0xCDBE2C45, 0x3FD5AF46,
    0x7198540D, 0x83F3D70E, 0x90A324FA, 0x62C8A7F9,
    0xB602C312, 0x44694011, 0x5739B3E5, 0xA55230E6,
    0xFB410CC2, 0x092A8FC1, 0x1A7A7C35, 0xE811FF36,
    0x3CDB9BDD, 0xCEB018DE, 0xDDE0EB2A, 0x2F8B6829,
    0x82F63B78, 0x70B0B87B, 0x63E06B8F, 0x91ABE88C,
    0x45618C67, 0xB70A0F64, 0xA45AFC90, 0x56317F93,
    0x082243B7, 0xFA49C0B4, 0xE9193340, 0x1B72B043,
    0xCFB8D4A8, 0x3DD357AB, 0x2E83A45F, 0xDCE8275C,
    0x92A5DC17, 0x60CE5F14, 0x73B8ACE0, 0x81D32FE3,
    0x55194B08, 0xA772C80B, 0xB4223BFF, 0x4649B8FC,
    0x185A84D8, 0xEA3107DB, 0xF961F42F, 0x0B0A772C,
    0xDFC013C7, 0x2DAB90C4, 0x3EFB6330, 0xCC90E033,
    0xA2609556, 0x500B1655, 0x435BE5A1, 0xB13066A2,
    0x65FA0249, 0x9791814A, 0x84C172BE, 0x76AAF1BD,
    0x28B9CD99, 0xDAD24E9A, 0xC982BD6E, 0x3BE93E6D,
    0xEF235A86, 0x1D48D985, 0x0E182A71, 0xFC73A972,
    0xB23E5239, 0x4055D13A, 0x537522CE, 0xA11EA1CD,
    0x75D4C526, 0x87BF4625, 0x94EFB5D1, 0x66843CD2,
    0x389700F6, 0xCAFC83F5, 0xD9AC7001, 0x2BC7F302,
    0xFF0D97E9, 0x0D6614EA, 0x1E36E71E, 0xEC5D641D,
    0xC3D60C34, 0x31BDB837, 0x22ED4BC3, 0xD086C8C0,
    0x044CAC2B, 0xF6272F28, 0xE577DCDC, 0x171C5FDF,
    0x490F63FB, 0xBB64E0F8, 0xA834130C, 0x5A5F900F,
    0x8E95F4E4, 0x7CFE77E7, 0x6FAE8413, 0x9DC50710,
    0xD388FC5B, 0x21E37F58, 0x32B38CAC, 0xC0D80FAF,
    0x14126B44, 0xE679E847, 0xF5291BB3, 0x079298B0,
    0x5981A494, 0xABEA2797, 0xB8BAD463, 0x4AD15760,
    0x9E1B338B, 0x6C70B088, 0x7F20437C, 0x8D4BC07F,
    0xE39B951A, 0x11F01619, 0x02A0E5ED, 0xF0CB66EE,
    0x24010205, 0xD66A8106, 0xC53A72F2, 0x3751F1F1,
    0x6942CDD5, 0x9B294ED6, 0x8879BD22, 0x7A123E21,
    0xAED85ACA, 0x5CB3D9C9, 0x4FE32A3D, 0xBD88A93E,
    0xF3C55275, 0x01AED176, 0x12FE2282, 0xE095A181,
    0x345FC56A, 0xC6344669, 0xD564B59D, 0x270F369E,
    0x791C0ABA, 0x8B7789B9, 0x98277A4D, 0x6A4CF94E,
    0xBE869DA5, 0x4CED1EA6, 0x5FBDED52, 0xADD66E51,
};

static uint32_t
crc32c_software(uint32_t crc, const uint8_t *buf, size_t len)
{
    crc = ~crc;
    for (size_t i = 0; i < len; i++) {
        crc = crc32c_table[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

#endif /* NN_CRC32C_SW */

/* ---------------------------------------------------------------------------
 * x86_64 SSE4.2 implementation
 * ------------------------------------------------------------------------- */

#ifdef NN_CRC32C_X86

static uint32_t
crc32c_hardware(uint32_t crc, const uint8_t *buf, size_t len)
{
    crc = ~crc;

    /* Process 8 bytes at a time */
    while (len >= 8) {
        uint64_t val;
        memcpy(&val, buf, sizeof(val));
        crc = (uint32_t)_mm_crc32_u64((uint64_t)crc, val);
        buf += 8;
        len -= 8;
    }

    /* Process remaining bytes */
    while (len > 0) {
        crc = _mm_crc32_u8(crc, *buf);
        buf++;
        len--;
    }

    return ~crc;
}

#endif /* NN_CRC32C_X86 */

/* ---------------------------------------------------------------------------
 * aarch64 ARMv8 CRC implementation
 * ------------------------------------------------------------------------- */

#ifdef NN_CRC32C_ARM

static uint32_t
crc32c_hardware(uint32_t crc, const uint8_t *buf, size_t len)
{
    crc = ~crc;

    /* Process 8 bytes at a time */
    while (len >= 8) {
        uint64_t val;
        memcpy(&val, buf, sizeof(val));
        crc = __crc32cd(crc, val);
        buf += 8;
        len -= 8;
    }

    /* Process remaining bytes */
    while (len > 0) {
        crc = __crc32cb(crc, *buf);
        buf++;
        len--;
    }

    return ~crc;
}

#endif /* NN_CRC32C_ARM */

/* ---------------------------------------------------------------------------
 * Public API
 * ------------------------------------------------------------------------- */

uint32_t
nn_crc32c(const uint8_t *buf, size_t len)
{
#ifdef NN_CRC32C_SW
    return crc32c_software(0, buf, len);
#else
    return crc32c_hardware(0, buf, len);
#endif
}

size_t
nn_crc32c_append(uint8_t *buf, size_t data_len)
{
    uint32_t crc = nn_crc32c(buf, data_len);
    nn_write_u32le(buf + data_len, crc);
    return data_len + NN_CRC32C_SIZE;
}

size_t
nn_crc32c_validate(const uint8_t *buf, size_t total_len)
{
    if (total_len < NN_CRC32C_SIZE)
        return 0;

    size_t payload_len = total_len - NN_CRC32C_SIZE;
    uint32_t expected = nn_read_u32le(buf + payload_len);
    uint32_t actual   = nn_crc32c(buf, payload_len);

    if (actual != expected)
        return 0;

    return payload_len;
}
