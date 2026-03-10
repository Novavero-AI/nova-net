-- |
-- Module      : NovaNet.Channel
-- Description : Per-channel message delivery with 5 modes
--
-- Pure Haskell module.  Channel operations run at message frequency
-- (tens per second), not packet frequency.  Data structures are
-- IntMap, Seq, and IntSet from containers.
module NovaNet.Channel
  ( -- * Channel state
    Channel,
    newChannel,
    resetChannel,

    -- * Send operations
    channelSend,
    OutgoingMessage (..),
    ChannelSendError (..),

    -- * Receive operations
    onMessageReceived,
    channelReceive,

    -- * Reliability integration
    acknowledgeMessage,
    getRetransmitMessages,

    -- * Periodic update
    channelUpdate,

    -- * Queries
    channelIsReliable,
    channelSendQueueLen,

    -- * Accessors
    chStatsSent,
    chStatsReceived,
    chStatsDropped,
    chStatsRetransmits,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.IntMap.Strict as IM
import qualified Data.IntSet as IS
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word16, Word64)
import NovaNet.Config (ChannelConfig (..))
import NovaNet.FFI.Seq (seqGt)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Maximum dedup set size before cleanup triggers.
maxDedupSetSize :: Int
maxDedupSetSize = 512

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | Per-channel send buffer entry (reliable modes only).
data SendEntry = SendEntry
  { sePayload :: !ByteString,
    seSendTime :: !MonoTime,
    seRetryCount :: !Int
  }

-- | Out-of-order buffered message (ReliableOrdered only).
data OooEntry = OooEntry
  { ooePayload :: !ByteString,
    ooeArrivalTime :: !MonoTime
  }

-- | Message ready to be sent as a packet.
data OutgoingMessage = OutgoingMessage
  { omChannelId :: !ChannelId,
    omChannelSeq :: !SequenceNum,
    omPayload :: !ByteString,
    omReliable :: !Bool
  }
  deriving (Show)

-- | Why a channel send was rejected.
data ChannelSendError
  = MessageTooLarge
  | BufferFull
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Channel state
-- ---------------------------------------------------------------------------

-- | Per-channel state.  One per ChannelId per connection.
data Channel = Channel
  { chConfig :: !ChannelConfig,
    chChannelId :: !ChannelId,
    chSendSeq :: !SequenceNum,
    chRecvSeq :: !SequenceNum,
    chExpectedSeq :: !SequenceNum,
    chSendBuffer :: !(IM.IntMap SendEntry),
    chReceiveQueue :: !(Seq ByteString),
    chOrderedBuffer :: !(IM.IntMap OooEntry),
    chRecvSeen :: !IS.IntSet,
    chStatsSent :: !Word64,
    chStatsReceived :: !Word64,
    chStatsDropped :: !Word64,
    chStatsRetransmits :: !Word64
  }

-- | Create a new channel with the given ID and config.
newChannel :: ChannelId -> ChannelConfig -> Channel
newChannel cid cfg =
  Channel
    { chConfig = cfg,
      chChannelId = cid,
      chSendSeq = initialSeq,
      chRecvSeq = initialSeq,
      chExpectedSeq = initialSeq,
      chSendBuffer = IM.empty,
      chReceiveQueue = Seq.empty,
      chOrderedBuffer = IM.empty,
      chRecvSeen = IS.empty,
      chStatsSent = 0,
      chStatsReceived = 0,
      chStatsDropped = 0,
      chStatsRetransmits = 0
    }

-- | Reset channel to initial state (preserves config and ID).
resetChannel :: Channel -> Channel
resetChannel ch = newChannel (chChannelId ch) (chConfig ch)

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Does this channel use reliable delivery?
channelIsReliable :: Channel -> Bool
channelIsReliable = isReliable . ccDeliveryMode . chConfig

-- | Number of messages in the send buffer awaiting ACK.
channelSendQueueLen :: Channel -> Int
channelSendQueueLen = IM.size . chSendBuffer

-- ---------------------------------------------------------------------------
-- Send
-- ---------------------------------------------------------------------------

-- | Enqueue a message for sending.  Returns the outgoing message
-- and updated channel, or an error.
channelSend ::
  ByteString ->
  MonoTime ->
  Channel ->
  Either ChannelSendError (OutgoingMessage, Channel)
channelSend payload now ch
  | BS.length payload > ccMaxMessageSize (chConfig ch) =
      Left MessageTooLarge
  | channelIsReliable ch && bufferFull && isBlock =
      Left BufferFull
  | otherwise =
      let seq_ = chSendSeq ch
          msg =
            OutgoingMessage
              { omChannelId = chChannelId ch,
                omChannelSeq = seq_,
                omPayload = payload,
                omReliable = channelIsReliable ch
              }
          sendBuf
            | channelIsReliable ch =
                let trimmed
                      | bufferFull = IM.deleteMin (chSendBuffer ch)
                      | otherwise = chSendBuffer ch
                    entry = SendEntry payload now 0
                 in IM.insert (seqKey seq_) entry trimmed
            | otherwise = chSendBuffer ch
          updated =
            ch
              { chSendSeq = nextSeq seq_,
                chSendBuffer = sendBuf,
                chStatsSent = chStatsSent ch + 1
              }
       in Right (msg, updated)
  where
    bufferFull = IM.size (chSendBuffer ch) >= ccMessageBufferSize (chConfig ch)
    isBlock = ccFullBufferPolicy (chConfig ch) == BlockOnFull

-- ---------------------------------------------------------------------------
-- Receive
-- ---------------------------------------------------------------------------

-- | Process an incoming channel message.
onMessageReceived ::
  SequenceNum ->
  ByteString ->
  MonoTime ->
  Channel ->
  Channel
onMessageReceived seq_ payload now ch =
  case ccDeliveryMode (chConfig ch) of
    Unreliable -> deliverImmediate seq_ payload ch
    UnreliableSequenced -> receiveSequenced seq_ payload ch
    ReliableUnordered -> receiveReliableUnordered seq_ payload ch
    ReliableOrdered -> receiveReliableOrdered seq_ payload now ch
    ReliableSequenced -> receiveSequenced seq_ payload ch

-- | Drain all delivered messages.
channelReceive :: Channel -> ([ByteString], Channel)
channelReceive ch =
  let msgs = foldr (:) [] (chReceiveQueue ch)
   in (msgs, ch {chReceiveQueue = Seq.empty})

-- ---------------------------------------------------------------------------
-- Receive: per-mode implementations
-- ---------------------------------------------------------------------------

deliverImmediate :: SequenceNum -> ByteString -> Channel -> Channel
deliverImmediate _ payload ch =
  ch
    { chReceiveQueue = chReceiveQueue ch |> payload,
      chStatsReceived = chStatsReceived ch + 1
    }

receiveSequenced :: SequenceNum -> ByteString -> Channel -> Channel
receiveSequenced seq_ payload ch
  | seqGt (unSequenceNum seq_) (unSequenceNum (chRecvSeq ch)) =
      ch
        { chRecvSeq = seq_,
          chReceiveQueue = chReceiveQueue ch |> payload,
          chStatsReceived = chStatsReceived ch + 1
        }
  | otherwise =
      ch {chStatsDropped = chStatsDropped ch + 1}

receiveReliableUnordered :: SequenceNum -> ByteString -> Channel -> Channel
receiveReliableUnordered seq_ payload ch
  | IS.member key (chRecvSeen ch) =
      ch {chStatsDropped = chStatsDropped ch + 1}
  | otherwise =
      ch
        { chRecvSeen = IS.insert key (chRecvSeen ch),
          chReceiveQueue = chReceiveQueue ch |> payload,
          chStatsReceived = chStatsReceived ch + 1
        }
  where
    key = seqKey seq_

receiveReliableOrdered :: SequenceNum -> ByteString -> MonoTime -> Channel -> Channel
receiveReliableOrdered seq_ payload now ch
  | unSequenceNum seq_ == unSequenceNum (chExpectedSeq ch) =
      -- Expected sequence: deliver and flush consecutive buffered messages
      let delivered = chReceiveQueue ch |> payload
          advanced = nextSeq seq_
       in flushConsecutive
            ch
              { chExpectedSeq = advanced,
                chReceiveQueue = delivered,
                chStatsReceived = chStatsReceived ch + 1
              }
  | seqGt (unSequenceNum seq_) (unSequenceNum (chExpectedSeq ch)) =
      -- Future sequence: buffer if room
      let key = seqKey seq_
       in if IM.member key (chOrderedBuffer ch)
            || IM.size (chOrderedBuffer ch) >= ccMaxOrderedBufferSize (chConfig ch)
            then ch {chStatsDropped = chStatsDropped ch + 1}
            else
              ch
                { chOrderedBuffer =
                    IM.insert key (OooEntry payload now) (chOrderedBuffer ch)
                }
  | otherwise =
      -- Behind expected: duplicate
      ch {chStatsDropped = chStatsDropped ch + 1}

-- | Flush consecutive messages from the ordered buffer starting at chExpectedSeq.
flushConsecutive :: Channel -> Channel
flushConsecutive ch =
  let key = seqKey (chExpectedSeq ch)
   in case IM.lookup key (chOrderedBuffer ch) of
        Nothing -> ch
        Just ooe ->
          flushConsecutive
            ch
              { chExpectedSeq = nextSeq (chExpectedSeq ch),
                chReceiveQueue = chReceiveQueue ch |> ooePayload ooe,
                chOrderedBuffer = IM.delete key (chOrderedBuffer ch),
                chStatsReceived = chStatsReceived ch + 1
              }

-- ---------------------------------------------------------------------------
-- Reliability integration
-- ---------------------------------------------------------------------------

-- | Mark a channel-local sequence as acknowledged.  Removes from send buffer.
acknowledgeMessage :: SequenceNum -> Channel -> Channel
acknowledgeMessage seq_ ch =
  ch {chSendBuffer = IM.delete (seqKey seq_) (chSendBuffer ch)}

-- | Find messages that need retransmission (RTO expired).
-- Returns the messages and updated channel with bumped retry counts.
-- Messages exceeding max retries are dropped.
getRetransmitMessages ::
  MonoTime ->
  Word64 ->
  Channel ->
  ([OutgoingMessage], Channel)
getRetransmitMessages now rtoNs ch
  | not (channelIsReliable ch) = ([], ch)
  | otherwise =
      let maxRetries = ccMaxReliableRetries (chConfig ch)
          process (msgs, buf, retrans, dropped) key entry
            | elapsed > rtoNs && seRetryCount entry >= maxRetries =
                -- Exceeded max retries: drop
                (msgs, IM.delete key buf, retrans, dropped + 1)
            | elapsed > rtoNs =
                -- RTO expired: retransmit
                let msg =
                      OutgoingMessage
                        { omChannelId = chChannelId ch,
                          omChannelSeq = SequenceNum (fromIntegral key),
                          omPayload = sePayload entry,
                          omReliable = True
                        }
                    updated =
                      entry
                        { seSendTime = now,
                          seRetryCount = seRetryCount entry + 1
                        }
                 in (msg : msgs, IM.insert key updated buf, retrans + 1, dropped)
            | otherwise =
                (msgs, buf, retrans, dropped)
            where
              elapsed = diffNs (seSendTime entry) now
          (retransMsgs, newBuf, retransCount, dropCount) =
            IM.foldlWithKey' process ([], chSendBuffer ch, 0 :: Word64, 0 :: Word64) (chSendBuffer ch)
       in ( reverse retransMsgs,
            ch
              { chSendBuffer = newBuf,
                chStatsRetransmits = chStatsRetransmits ch + retransCount,
                chStatsDropped = chStatsDropped ch + dropCount
              }
          )

-- ---------------------------------------------------------------------------
-- Periodic update
-- ---------------------------------------------------------------------------

-- | Per-tick update.  Flushes timed-out ordered buffer entries
-- and cleans up the dedup set.
channelUpdate :: MonoTime -> Channel -> Channel
channelUpdate now ch =
  let flushed = flushTimedOutOrdered now ch
   in cleanupDedupSet flushed

-- | Flush ordered buffer entries that have been waiting too long.
flushTimedOutOrdered :: MonoTime -> Channel -> Channel
flushTimedOutOrdered now ch
  | ccDeliveryMode (chConfig ch) /= ReliableOrdered = ch
  | IM.null (chOrderedBuffer ch) = ch
  | otherwise =
      let timeoutNs = msToNs (ccOrderedBufferTimeoutMs (chConfig ch))
          isTimedOut ooe = diffNs (ooeArrivalTime ooe) now >= timeoutNs
          timedOut = IM.filter isTimedOut (chOrderedBuffer ch)
       in if IM.null timedOut
            then ch
            else
              -- Deliver timed-out messages in key order, advance expected seq
              let delivered =
                    IM.foldlWithKey'
                      (\q _ ooe -> q |> ooePayload ooe)
                      (chReceiveQueue ch)
                      timedOut
                  remaining = IM.difference (chOrderedBuffer ch) timedOut
                  -- Find highest key and advance expected past it
                  highestKey = fst (IM.findMax timedOut)
                  newExpected = nextSeq (SequenceNum (fromIntegral highestKey))
                  -- Only advance if it's actually ahead
                  finalExpected
                    | seqGt (unSequenceNum newExpected) (unSequenceNum (chExpectedSeq ch)) =
                        newExpected
                    | otherwise = chExpectedSeq ch
               in flushConsecutive
                    ch
                      { chReceiveQueue = delivered,
                        chOrderedBuffer = remaining,
                        chExpectedSeq = finalExpected,
                        chStatsReceived = chStatsReceived ch + fromIntegral (IM.size timedOut)
                      }

-- | Remove stale entries from the dedup set (ReliableUnordered).
cleanupDedupSet :: Channel -> Channel
cleanupDedupSet ch
  | ccDeliveryMode (chConfig ch) /= ReliableUnordered = ch
  | IS.size (chRecvSeen ch) <= maxDedupSetSize = ch
  | otherwise =
      -- Keep only the most recent entries (within half the sequence space)
      let recvRaw = fromIntegral (unSequenceNum (chRecvSeq ch)) :: Int
          keepPred key =
            let dist = abs (recvRaw - key)
             in dist < fromIntegral (seqHalfRange :: Word16)
       in ch {chRecvSeen = IS.filter keepPred (chRecvSeen ch)}
  where
    seqHalfRange :: Word16
    seqHalfRange = 32768

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Convert a SequenceNum to an IntMap key.
seqKey :: SequenceNum -> Int
seqKey = fromIntegral . unSequenceNum
