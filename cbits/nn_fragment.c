/*
 * nn_fragment.c — Message fragmentation and reassembly
 */

#include "nn_fragment.h"
#include "nn_wire.h"
#include <string.h>

int
nn_fragment_write(const nn_fragment_header *hdr, uint8_t *buf)
{
    if (hdr->fragment_count == 0 || hdr->fragment_index >= hdr->fragment_count)
        return -1;

    nn_write_u32le(buf, hdr->message_id);
    buf[4] = hdr->fragment_index;
    buf[5] = hdr->fragment_count;
    return NN_FRAGMENT_HEADER_SIZE;
}

int
nn_fragment_read(const uint8_t *buf, size_t buf_len, nn_fragment_header *out)
{
    if (buf_len < NN_FRAGMENT_HEADER_SIZE)
        return -1;

    out->message_id     = nn_read_u32le(buf);
    out->fragment_index = buf[4];
    out->fragment_count = buf[5];

    if (out->fragment_count == 0 || out->fragment_index >= out->fragment_count)
        return -1;

    return 0;
}

int
nn_fragment_count(size_t msg_len, size_t max_payload)
{
    if (msg_len == 0)
        return 0;
    if (max_payload == 0)
        return -1;

    size_t count = (msg_len + max_payload - 1) / max_payload;
    if (count > NN_MAX_FRAGMENT_COUNT)
        return -1;

    return (int)count;
}

int
nn_fragment_build(const uint8_t *msg, size_t msg_len,
                  uint32_t message_id, uint8_t frag_index,
                  uint8_t frag_count, size_t max_payload,
                  uint8_t *out_buf)
{
    if (frag_index >= frag_count)
        return -1;

    size_t offset = (size_t)frag_index * max_payload;
    if (offset > msg_len)
        return -1;

    size_t payload_len = msg_len - offset;
    if (payload_len > max_payload)
        payload_len = max_payload;

    nn_fragment_header hdr = {
        .message_id     = message_id,
        .fragment_index = frag_index,
        .fragment_count = frag_count
    };
    nn_fragment_write(&hdr, out_buf);
    memcpy(out_buf + NN_FRAGMENT_HEADER_SIZE, msg + offset, payload_len);

    return (int)(NN_FRAGMENT_HEADER_SIZE + payload_len);
}
