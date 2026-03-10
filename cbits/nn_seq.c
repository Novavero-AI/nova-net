/*
 * nn_seq.c — Sequence numbers, ring buffers, and ACK bitfield processing
 */

#include "nn_seq.h"
#include <string.h>

/* ---------------------------------------------------------------------------
 * Received buffer
 * ------------------------------------------------------------------------- */

void
nn_recv_buf_init(nn_recv_buf *buf)
{
    memset(buf->seqs, 0xFF, sizeof(buf->seqs)); /* NN_SEQ_EMPTY = 0xFFFF */
    buf->highest = 0;
}

/* ---------------------------------------------------------------------------
 * Sent packet buffer
 * ------------------------------------------------------------------------- */

void
nn_sent_buf_init(nn_sent_buf *buf)
{
    memset(buf->entries, 0, sizeof(buf->entries));
    memset(buf->seq_nums, 0, sizeof(buf->seq_nums));
    buf->count = 0;
}

int
nn_sent_buf_insert(nn_sent_buf *buf, uint16_t seq,
                   const nn_sent_record *record)
{
    int idx = seq & NN_SEQ_RING_MASK;
    int was_occupied = buf->entries[idx].occupied;

    buf->entries[idx]  = *record;
    buf->entries[idx].occupied = 1;
    buf->seq_nums[idx] = seq;

    if (!was_occupied)
        buf->count++;

    return was_occupied ? 0 : 0; /* no eviction tracking needed at this level */
}

const nn_sent_record *
nn_sent_buf_lookup(const nn_sent_buf *buf, uint16_t seq)
{
    int idx = seq & NN_SEQ_RING_MASK;
    if (buf->entries[idx].occupied && buf->seq_nums[idx] == seq)
        return &buf->entries[idx];
    return NULL;
}

int
nn_sent_buf_delete(nn_sent_buf *buf, uint16_t seq)
{
    int idx = seq & NN_SEQ_RING_MASK;
    if (buf->entries[idx].occupied && buf->seq_nums[idx] == seq) {
        buf->entries[idx].occupied = 0;
        buf->count--;
        return 1;
    }
    return 0;
}

/* ---------------------------------------------------------------------------
 * Generic sequence buffer
 * ------------------------------------------------------------------------- */

void
nn_seq_buf_init(nn_seq_buf *buf)
{
    memset(buf->seq_nums, 0, sizeof(buf->seq_nums));
    memset(buf->occupied, 0, sizeof(buf->occupied));
    buf->highest = 0;
    buf->size = NN_SEQ_RING_SIZE;
}

/* ---------------------------------------------------------------------------
 * ACK bitfield
 * ------------------------------------------------------------------------- */

void
nn_ack_update(uint16_t *remote_seq, uint64_t *ack_bits, uint16_t seq)
{
    if (nn_seq_gt(seq, *remote_seq)) {
        int32_t d = nn_seq_diff(seq, *remote_seq);
        uint64_t shift = (uint64_t)d;
        if (shift < NN_ACK_BITS_WINDOW) {
            *ack_bits = (*ack_bits << shift) | (1ull << (shift - 1));
        } else {
            *ack_bits = 0;
        }
        *remote_seq = seq;
    } else {
        int32_t d = nn_seq_diff(*remote_seq, seq);
        if (d > 0 && (uint64_t)d <= NN_ACK_BITS_WINDOW) {
            *ack_bits |= (1ull << ((uint64_t)d - 1));
        }
    }
}

/* ---------------------------------------------------------------------------
 * Loss window
 * ------------------------------------------------------------------------- */

/** Number of loss window samples. */
#define LOSS_WINDOW_SIZE 256

void
nn_loss_window_init(nn_loss_window *lw)
{
    memset(lw->bits, 0, sizeof(lw->bits));
    lw->index = 0;
    lw->count = 0;
}

void
nn_loss_window_record(nn_loss_window *lw, int lost)
{
    int idx = lw->index & (LOSS_WINDOW_SIZE - 1);
    int word = idx >> 6;    /* idx / 64 */
    int bit  = idx & 63;    /* idx % 64 */

    if (lost)
        lw->bits[word] |=  (1ull << bit);
    else
        lw->bits[word] &= ~(1ull << bit);

    lw->index++;
    if (lw->count < LOSS_WINDOW_SIZE)
        lw->count++;
}

/* Portable popcount */
static int
popcount64(uint64_t x)
{
#if defined(__GNUC__) || defined(__clang__)
    return __builtin_popcountll(x);
#else
    x = x - ((x >> 1) & 0x5555555555555555ull);
    x = (x & 0x3333333333333333ull) + ((x >> 2) & 0x3333333333333333ull);
    x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0Full;
    return (int)((x * 0x0101010101010101ull) >> 56);
#endif
}

double
nn_loss_window_percent(const nn_loss_window *lw)
{
    if (lw->count == 0)
        return 0.0;

    int total_lost = 0;
    int remaining = lw->count;

    for (int i = 0; i < 4 && remaining > 0; i++) {
        if (remaining >= 64) {
            total_lost += popcount64(lw->bits[i]);
            remaining -= 64;
        } else {
            uint64_t mask = (1ull << remaining) - 1;
            total_lost += popcount64(lw->bits[i] & mask);
            remaining = 0;
        }
    }

    return (double)total_lost / (double)lw->count;
}
