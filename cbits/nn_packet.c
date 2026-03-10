/*
 * nn_packet.c — Wire packet header serialization
 */

#include "nn_packet.h"

/* Bit shift for packet type in byte 0. */
#define PACKET_TYPE_SHIFT 4

int
nn_packet_write(const nn_packet_header *hdr, uint8_t *buf)
{
    if (hdr->packet_type > NN_PACKET_TYPE_MAX)
        return -1;

    const uint8_t  pt  = hdr->packet_type;
    const uint16_t sn  = hdr->sequence_num;
    const uint16_t ak  = hdr->ack;
    const uint32_t abf = hdr->ack_bitfield;

    buf[0] = (uint8_t)((pt  << PACKET_TYPE_SHIFT) | (sn >> 12));
    buf[1] = (uint8_t)(sn >> 4);
    buf[2] = (uint8_t)(((sn & 0x0Fu) << 4) | (ak >> 12));
    buf[3] = (uint8_t)(ak >> 4);
    buf[4] = (uint8_t)(((ak & 0x0Fu) << 4) | (abf >> 28));
    buf[5] = (uint8_t)(abf >> 20);
    buf[6] = (uint8_t)(abf >> 12);
    buf[7] = (uint8_t)(abf >> 4);
    buf[8] = (uint8_t)((abf & 0x0Fu) << 4);

    return NN_PACKET_HEADER_SIZE;
}

int
nn_packet_read(const uint8_t *buf, size_t buf_len, nn_packet_header *out)
{
    if (buf_len < NN_PACKET_HEADER_SIZE)
        return -1;

    const uint8_t b0 = buf[0];
    const uint8_t b1 = buf[1];
    const uint8_t b2 = buf[2];
    const uint8_t b3 = buf[3];
    const uint8_t b4 = buf[4];
    const uint8_t b5 = buf[5];
    const uint8_t b6 = buf[6];
    const uint8_t b7 = buf[7];
    const uint8_t b8 = buf[8];

    const uint8_t pt = b0 >> PACKET_TYPE_SHIFT;
    if (pt > NN_PACKET_TYPE_MAX)
        return -1;

    const uint16_t sn = (uint16_t)(((uint16_t)(b0 & 0x0Fu) << 12)
                                  | ((uint16_t)b1 << 4)
                                  | ((uint16_t)(b2 >> 4)));

    const uint16_t ak = (uint16_t)(((uint16_t)(b2 & 0x0Fu) << 12)
                                  | ((uint16_t)b3 << 4)
                                  | ((uint16_t)(b4 >> 4)));

    const uint32_t abf = ((uint32_t)(b4 & 0x0Fu) << 28)
                        | ((uint32_t)b5 << 20)
                        | ((uint32_t)b6 << 12)
                        | ((uint32_t)b7 << 4)
                        | ((uint32_t)(b8 >> 4));

    out->packet_type  = pt;
    out->sequence_num = sn;
    out->ack          = ak;
    out->ack_bitfield = abf;

    return 0;
}
