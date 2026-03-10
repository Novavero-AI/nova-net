/*
 * nn_batch.c — Message batching and unbatching
 */

#include "nn_batch.h"
#include "nn_wire.h"
#include <string.h>

/* ---------------------------------------------------------------------------
 * Batch writer
 * ------------------------------------------------------------------------- */

void
nn_batch_writer_init(nn_batch_writer *w, uint8_t *buf, size_t capacity)
{
    w->buf      = buf;
    w->capacity = capacity;
    w->offset   = NN_BATCH_HEADER_SIZE; /* reserve byte 0 for count */
    w->count    = 0;
}

int
nn_batch_writer_add(nn_batch_writer *w,
                    const uint8_t *msg, size_t msg_len)
{
    if (w->count >= NN_BATCH_MAX_MESSAGES)
        return -1;

    if (msg_len > UINT16_MAX)
        return -1;

    size_t needed = NN_BATCH_LENGTH_SIZE + msg_len;
    if (w->offset + needed > w->capacity)
        return -1;

    nn_write_u16le(w->buf + w->offset, (uint16_t)msg_len);
    w->offset += NN_BATCH_LENGTH_SIZE;

    memcpy(w->buf + w->offset, msg, msg_len);
    w->offset += msg_len;

    w->count++;
    return 0;
}

size_t
nn_batch_writer_finish(nn_batch_writer *w)
{
    if (w->count == 0)
        return 0;

    w->buf[0] = w->count;
    return w->offset;
}

/* ---------------------------------------------------------------------------
 * Batch reader
 * ------------------------------------------------------------------------- */

int
nn_batch_reader_init(nn_batch_reader *r,
                     const uint8_t *buf, size_t buf_len)
{
    if (buf_len < NN_BATCH_HEADER_SIZE)
        return -1;

    r->buf     = buf;
    r->buf_len = buf_len;
    r->offset  = NN_BATCH_HEADER_SIZE;
    r->count   = buf[0];
    r->read    = 0;
    return 0;
}

int
nn_batch_reader_next(nn_batch_reader *r,
                     const uint8_t **out_msg, size_t *out_len)
{
    if (r->read >= r->count)
        return -1;

    if (r->offset + NN_BATCH_LENGTH_SIZE > r->buf_len)
        return -1;

    uint16_t msg_len = nn_read_u16le(r->buf + r->offset);
    r->offset += NN_BATCH_LENGTH_SIZE;

    if (r->offset + msg_len > r->buf_len)
        return -1;

    *out_msg = r->buf + r->offset;
    *out_len = msg_len;
    r->offset += msg_len;
    r->read++;
    return 0;
}
