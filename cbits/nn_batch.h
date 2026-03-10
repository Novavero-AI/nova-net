/*
 * nn_batch.h — Message batching and unbatching
 *
 * Packs multiple small messages into a single packet for efficiency.
 *
 * Batch wire format (all little-endian):
 *   Byte 0:       message_count (uint8_t, max 255)
 *   Per message:
 *     Bytes 0-1:  message_length (uint16_t LE)
 *     Bytes 2+:   message_data
 *
 * NOTE: gbnet-hs used big-endian for message lengths. nova-net uses LE.
 */

#ifndef NN_BATCH_H
#define NN_BATCH_H

#include <stddef.h>
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Batch header overhead: 1 byte for message count. */
#define NN_BATCH_HEADER_SIZE 1

/** Per-message length prefix: 2 bytes. */
#define NN_BATCH_LENGTH_SIZE 2

/** Maximum messages per batch (uint8_t). */
#define NN_BATCH_MAX_MESSAGES 255

/* ---------------------------------------------------------------------------
 * Batch writer — pack messages into a buffer
 * ------------------------------------------------------------------------- */

typedef struct {
    uint8_t *buf;       /* output buffer */
    size_t   capacity;  /* max bytes in buf */
    size_t   offset;    /* current write position */
    uint8_t  count;     /* messages written so far */
} nn_batch_writer;

/** Initialize a batch writer. Writes the count byte (updated on finish). */
void nn_batch_writer_init(nn_batch_writer *w, uint8_t *buf, size_t capacity);

/**
 * Append a message to the batch.
 * Returns 0 on success, -1 if the message doesn't fit or batch is full.
 */
int nn_batch_writer_add(nn_batch_writer *w,
                        const uint8_t *msg, size_t msg_len);

/**
 * Finalize the batch. Writes the message count into byte 0.
 * Returns total batch size in bytes, or 0 if empty.
 */
size_t nn_batch_writer_finish(nn_batch_writer *w);

/* ---------------------------------------------------------------------------
 * Batch reader — unpack messages from a buffer
 * ------------------------------------------------------------------------- */

typedef struct {
    const uint8_t *buf;
    size_t         buf_len;
    size_t         offset;   /* current read position */
    uint8_t        count;    /* total messages in batch */
    uint8_t        read;     /* messages read so far */
} nn_batch_reader;

/**
 * Initialize a batch reader. Returns 0 on success, -1 if buf is too short.
 */
int nn_batch_reader_init(nn_batch_reader *r,
                         const uint8_t *buf, size_t buf_len);

/**
 * Read the next message. Sets *out_msg and *out_len.
 * Returns 0 on success, -1 if no more messages or parse error.
 */
int nn_batch_reader_next(nn_batch_reader *r,
                         const uint8_t **out_msg, size_t *out_len);

#endif /* NN_BATCH_H */
