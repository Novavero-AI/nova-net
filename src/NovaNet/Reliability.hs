-- |
-- Module      : NovaNet.Reliability
-- Description : Reliable packet delivery orchestration
--
-- Thin Haskell layer over the C hot path.  Owns the C state
-- (sent buffer, recv buffer, loss window, RTT estimator) and
-- provides a clean API for the Channel and Connection layers.
module NovaNet.Reliability
  ( -- * Reliable endpoint
    ReliableEndpoint,
    newReliableEndpoint,

    -- * Sequence allocation
    allocateSeq,

    -- * Send-side
    onPacketSent,

    -- * Receive-side
    onPacketReceived,
    AckOutcome (..),
    processIncomingAck,

    -- * Outgoing header info
    getAckInfo,

    -- * ACK bitfield update (pure)
    ackUpdate,
    ackBitsWindow,

    -- * Accessors
    reTotalSent,
    reTotalAcked,
    reTotalLost,
    reBytesSent,
    reBytesAcked,
    reRemoteSeq,

    -- * Queries
    packetsInFlight,
    packetLossPercent,
    getRtoNs,
    getSrttNs,

    -- * Connection migration
    resetMetrics,
  )
where

import Control.Monad (when)
import Data.Bits (shiftL, (.&.), (.|.))
import Data.Int (Int32, Int64)
import Data.Word (Word16, Word32, Word64)
import NovaNet.FFI.AckProcess (AckResult (..), processAcks)
import NovaNet.FFI.LossWindow (LossWindow, lossPercent, newLossWindow, withLossWindow)
import NovaNet.FFI.RecvBuf (RecvBuf, newRecvBuf, recvBufExists, recvBufInsert)
import NovaNet.FFI.Rtt (RttEstimator, newRttEstimator, rttGetRto, rttGetSrtt, rttUpdate)
import NovaNet.FFI.SentBuf (SentBuf, newSentBuf, sentBufCount, sentBufInsert, withSentBuf)
import NovaNet.FFI.Seq (seqDiff, seqGt)
import NovaNet.Types
  ( ChannelId,
    MonoTime (..),
    SequenceNum (..),
    initialSeq,
    nextSeq,
    unChannelId,
  )

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Number of ACK bits tracked internally (64-bit).
-- Only the lower 32 are sent on the wire.
ackBitsWindow :: Word64
ackBitsWindow = 64

-- ---------------------------------------------------------------------------
-- Reliable endpoint
-- ---------------------------------------------------------------------------

-- | Per-connection reliability state.
data ReliableEndpoint = ReliableEndpoint
  { reSentBuf :: !SentBuf,
    reRecvBuf :: !RecvBuf,
    reLossWindow :: !LossWindow,
    reRttEstimator :: !RttEstimator,
    reLocalSeq :: !SequenceNum,
    reRemoteSeq :: !Word16,
    reAckBits :: !Word64,
    reTotalSent :: !Word64,
    reTotalAcked :: !Word64,
    reTotalLost :: !Word64,
    reBytesSent :: !Word64,
    reBytesAcked :: !Word64,
    reMaxSeqDist :: !Word16
  }

-- | Create a new reliable endpoint.
newReliableEndpoint :: Word16 -> IO ReliableEndpoint
newReliableEndpoint maxSeqDist = do
  sb <- newSentBuf
  rb <- newRecvBuf
  lw <- newLossWindow
  rtt <- newRttEstimator
  pure
    ReliableEndpoint
      { reSentBuf = sb,
        reRecvBuf = rb,
        reLossWindow = lw,
        reRttEstimator = rtt,
        reLocalSeq = initialSeq,
        reRemoteSeq = 0,
        reAckBits = 0,
        reTotalSent = 0,
        reTotalAcked = 0,
        reTotalLost = 0,
        reBytesSent = 0,
        reBytesAcked = 0,
        reMaxSeqDist = maxSeqDist
      }

-- ---------------------------------------------------------------------------
-- Sequence allocation
-- ---------------------------------------------------------------------------

-- | Allocate the next sequence number (pure).
allocateSeq :: ReliableEndpoint -> (SequenceNum, ReliableEndpoint)
allocateSeq ep =
  let seq_ = reLocalSeq ep
   in (seq_, ep {reLocalSeq = nextSeq seq_})

-- ---------------------------------------------------------------------------
-- Send-side
-- ---------------------------------------------------------------------------

-- | Record a sent packet in the sent buffer.
onPacketSent ::
  ReliableEndpoint ->
  SequenceNum ->
  ChannelId ->
  SequenceNum ->
  MonoTime ->
  Int ->
  IO ReliableEndpoint
onPacketSent ep seq_ chanId chanSeq sendTime pktSize = do
  _ <-
    sentBufInsert
      (reSentBuf ep)
      (unSequenceNum seq_)
      (unChannelId chanId)
      (unSequenceNum chanSeq)
      (unMonoTime sendTime)
      (fromIntegral pktSize)
  pure
    ep
      { reTotalSent = reTotalSent ep + 1,
        reBytesSent = reBytesSent ep + fromIntegral pktSize
      }

-- ---------------------------------------------------------------------------
-- Receive-side
-- ---------------------------------------------------------------------------

-- | Process a received packet for dedup and ack state update.
-- Returns 'Nothing' if the packet is a duplicate or stale.
onPacketReceived ::
  ReliableEndpoint ->
  Word16 ->
  IO (Maybe ReliableEndpoint)
onPacketReceived ep seq_ = do
  let dist = abs (seqDiff seq_ (reRemoteSeq ep))
  if (fromIntegral dist :: Int) > fromIntegral (reMaxSeqDist ep)
    then pure Nothing
    else do
      isDup <- recvBufExists (reRecvBuf ep) seq_
      if isDup
        then pure Nothing
        else do
          recvBufInsert (reRecvBuf ep) seq_
          let (remoteSeq, ackBits) = ackUpdate (reRemoteSeq ep) (reAckBits ep) seq_
          pure (Just ep {reRemoteSeq = remoteSeq, reAckBits = ackBits})

-- | Outcome of processing an incoming ACK.
data AckOutcome = AckOutcome
  { aoAckedCount :: !Int32,
    aoAckedBytes :: !Int32,
    aoLostCount :: !Int32,
    aoFastRetransmit :: !Bool,
    aoRetransmitSeq :: !Word16
  }
  deriving (Eq, Show)

-- | Process ACK info from a received packet header.
-- Walks the ack bitfield against the sent buffer (one C call),
-- feeds RTT sample, updates counters.
processIncomingAck ::
  ReliableEndpoint ->
  Word16 ->
  Word32 ->
  MonoTime ->
  IO (AckOutcome, ReliableEndpoint)
processIncomingAck ep ackSeq ackBitfield now = do
  result <-
    withSentBuf (reSentBuf ep) $ \sentPtr ->
      withLossWindow (reLossWindow ep) $ \lwPtr ->
        processAcks sentPtr lwPtr ackSeq ackBitfield (unMonoTime now)

  when (arRttSampleNs result >= 0) $
    rttUpdate (reRttEstimator ep) (arRttSampleNs result)

  let outcome =
        AckOutcome
          { aoAckedCount = arAckedCount result,
            aoAckedBytes = arAckedBytes result,
            aoLostCount = arLostCount result,
            aoFastRetransmit = arFastRetransmit result,
            aoRetransmitSeq = arRetransmitSeq result
          }
      updated =
        ep
          { reTotalAcked = reTotalAcked ep + fromIntegral (max 0 (arAckedCount result)),
            reBytesAcked = reBytesAcked ep + fromIntegral (max 0 (arAckedBytes result)),
            reTotalLost = reTotalLost ep + fromIntegral (max 0 (arLostCount result))
          }
  pure (outcome, updated)

-- ---------------------------------------------------------------------------
-- Outgoing header info
-- ---------------------------------------------------------------------------

-- | Get (ack_seq, ack_bitfield) for writing into outgoing packet headers.
-- The 64-bit internal ack bits are truncated to 32-bit for the wire.
getAckInfo :: ReliableEndpoint -> (Word16, Word32)
getAckInfo ep = (reRemoteSeq ep, fromIntegral (reAckBits ep .&. 0xFFFFFFFF))

-- ---------------------------------------------------------------------------
-- ACK bitfield update (pure)
-- ---------------------------------------------------------------------------

-- | Update remote sequence and ack bitfield after receiving a packet.
-- Pure Haskell implementation using 'seqGt' and 'seqDiff' from C.
ackUpdate :: Word16 -> Word64 -> Word16 -> (Word16, Word64)
ackUpdate remoteSeq ackBits seq_
  | seqGt seq_ remoteSeq =
      let d = fromIntegral (seqDiff seq_ remoteSeq) :: Word64
          newBits
            | d < ackBitsWindow =
                (ackBits `shiftL` fromIntegral d) .|. (1 `shiftL` (fromIntegral d - 1))
            | otherwise = 0
       in (seq_, newBits)
  | otherwise =
      let d = fromIntegral (seqDiff remoteSeq seq_) :: Word64
          newBits
            | d > 0 && d <= ackBitsWindow =
                ackBits .|. (1 `shiftL` (fromIntegral d - 1))
            | otherwise = ackBits
       in (remoteSeq, newBits)

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Number of unacked packets currently tracked.
packetsInFlight :: ReliableEndpoint -> IO Int
packetsInFlight = sentBufCount . reSentBuf

-- | Current packet loss fraction (0.0 to 1.0).
packetLossPercent :: ReliableEndpoint -> IO Double
packetLossPercent = lossPercent . reLossWindow

-- | Current retransmission timeout in nanoseconds.
getRtoNs :: ReliableEndpoint -> IO Int64
getRtoNs = rttGetRto . reRttEstimator

-- | Current smoothed RTT in nanoseconds.
getSrttNs :: ReliableEndpoint -> IO Int64
getSrttNs = rttGetSrtt . reRttEstimator

-- ---------------------------------------------------------------------------
-- Connection migration
-- ---------------------------------------------------------------------------

-- | Reset RTT and loss metrics (new network path).
-- Sequence numbers and buffers are preserved for packet continuity.
resetMetrics :: ReliableEndpoint -> IO ReliableEndpoint
resetMetrics ep = do
  rtt <- newRttEstimator
  lw <- newLossWindow
  pure ep {reRttEstimator = rtt, reLossWindow = lw}
