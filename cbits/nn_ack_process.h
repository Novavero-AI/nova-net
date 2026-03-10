/*
 * nn_ack_process.h -- ACK bitfield processing
 *
 * Walks the 32-bit ack_bitfield from a received packet header,
 * correlates each bit with the sent buffer, marks acks and losses,
 * and signals fast retransmit.  Called once per received packet.
 */

#ifndef NN_ACK_PROCESS_H
#define NN_ACK_PROCESS_H

#include "nn_seq.h"
#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Constants
 * ------------------------------------------------------------------------- */

/** Number of bits in the wire ack_bitfield. */
#define NN_ACK_BITFIELD_BITS 32

/** Sentinel: no RTT sample available from this ACK. */
#define NN_ACK_NO_RTT_SAMPLE (-1LL)

/* ---------------------------------------------------------------------------
 * ACK processing result (lives on caller's stack)
 * ------------------------------------------------------------------------- */

typedef struct {
    int32_t  acked_count;       /* number of newly acked packets */
    int32_t  acked_bytes;       /* total bytes newly acked */
    int64_t  rtt_sample_ns;     /* RTT sample from the direct ack, -1 if none */
    int32_t  lost_count;        /* packets marked lost (gap in bitfield) */
    int32_t  fast_retransmit;   /* 1 if any entry hit nack threshold */
    uint16_t retransmit_seq;    /* sequence to retransmit (valid if fast_retransmit=1) */
} nn_ack_result;

/* ---------------------------------------------------------------------------
 * API
 * ------------------------------------------------------------------------- */

/**
 * Process an incoming ACK: walk the bitfield against the sent buffer.
 *
 * sent:          [in/out] sent packet buffer (entries deleted on ack)
 * lw:            [in/out] loss window (success/loss recorded per bit)
 * ack_seq:       the directly-acked sequence number from the packet header
 * ack_bitfield:  32-bit bitfield of preceding acks (bit i = ack_seq-1-i)
 * now_ns:        current monotonic time in nanoseconds
 * result:        [out] processing results (caller-provided, zeroed on entry)
 */
void nn_ack_process(nn_sent_buf *sent, nn_loss_window *lw,
                    uint16_t ack_seq, uint32_t ack_bitfield,
                    uint64_t now_ns, nn_ack_result *result);

#endif /* NN_ACK_PROCESS_H */
