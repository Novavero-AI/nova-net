/*
 * nn_ack_process.c -- ACK bitfield processing
 */

#include "nn_ack_process.h"
#include <string.h>

void
nn_ack_process(nn_sent_buf *sent, nn_loss_window *lw,
               uint16_t ack_seq, uint32_t ack_bitfield,
               uint64_t now_ns, nn_ack_result *result)
{
    memset(result, 0, sizeof(*result));
    result->rtt_sample_ns = NN_ACK_NO_RTT_SAMPLE;

    /* Direct ack: the ack_seq itself (RTT sample taken here only) */
    const nn_sent_record *rec = nn_sent_buf_lookup(sent, ack_seq);
    if (rec != NULL) {
        result->rtt_sample_ns = (int64_t)(now_ns - rec->send_time_ns);
        result->acked_count++;
        result->acked_bytes += (int32_t)rec->size;
        nn_loss_window_record(lw, 0);
        nn_sent_buf_delete(sent, ack_seq);
    }

    /* Walk bitfield: bit i represents (ack_seq - 1 - i) */
    for (int i = 0; i < NN_ACK_BITFIELD_BITS; i++) {
        uint16_t seq = (uint16_t)(ack_seq - 1 - i);

        if (ack_bitfield & (1u << i)) {
            /* Bit set: peer received this packet */
            const nn_sent_record *entry = nn_sent_buf_lookup(sent, seq);
            if (entry != NULL) {
                result->acked_count++;
                result->acked_bytes += (int32_t)entry->size;
                nn_loss_window_record(lw, 0);
                nn_sent_buf_delete(sent, seq);
            }
        } else {
            /* Bit clear: peer did NOT receive this packet */
            nn_sent_record *entry = nn_sent_buf_lookup_mut(sent, seq);
            if (entry != NULL) {
                entry->nack_count++;
                result->lost_count++;
                nn_loss_window_record(lw, 1);
                if (entry->nack_count >= NN_FAST_RETRANSMIT_THRESHOLD) {
                    result->fast_retransmit = 1;
                    result->retransmit_seq  = seq;
                }
            }
        }
    }
}
