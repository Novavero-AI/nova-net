-- |
-- Module      : NovaNet.Connection
-- Description : Single peer-to-peer connection state machine
--
-- Composes Reliability, Channel, and Congestion into a cohesive
-- connection.  Owns the packet-seq-to-channel mapping for ACK
-- resolution.  The Peer layer (Phase 4) manages multiple Connections.
module NovaNet.Connection
  ( -- * Connection
    Connection,
    newConnection,

    -- * State machine
    connect,
    disconnect,
    markConnected,

    -- * Send / Receive
    sendMessage,
    receiveMessages,
    receiveIncomingPayload,

    -- * Packet pipeline
    processIncomingHeader,
    processChannelOutput,
    processRetransmissions,
    drainSendQueue,
    OutgoingPacket (..),

    -- * Per-tick update
    updateTick,

    -- * Time tracking
    touchRecvTime,
    touchSendTime,

    -- * Queries
    connectionState,
    isConnected,
    channelCount,
    connReliability,

    -- * Fragment processing
    processFragment,
    allocateMessageId,

    -- * Reset
    resetTransportMetrics,

    -- * ACK resolution (pure, exported for testing)
    resolveChannelAcks,

    -- * Errors
    ConnectionError (..),
  )
where

import Control.Monad (when)
import Data.Bits (testBit)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.IntMap.Strict as IM
import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word16, Word32)
import NovaNet.Channel
import NovaNet.Config
import NovaNet.Congestion
import NovaNet.FFI.Bandwidth (BandwidthTracker, bandwidthRecord, newBandwidthTracker)
import NovaNet.Fragment (FragmentAssembler, assemblerUpdate, newFragmentAssembler, onFragmentReceived)
import NovaNet.Reliability
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Bandwidth tracker measurement window in milliseconds.
bandwidthWindowMs :: Double
bandwidthWindowMs = 1000.0

-- | Number of bits in the wire ack bitfield.
ackBitfieldBits :: Int
ackBitfieldBits = 32

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | A packet ready to be serialized and sent.
data OutgoingPacket = OutgoingPacket
  { opPacketType :: !PacketType,
    opSeq :: !SequenceNum,
    opAckSeq :: !Word16,
    opAckBits :: !Word32,
    opPayload :: !ByteString
  }
  deriving (Show)

-- | Why a connection-level operation failed.
data ConnectionError
  = ErrNotConnected
  | ErrAlreadyConnected
  | ErrInvalidChannel
  | ErrChannelSend !ChannelSendError
  | ErrTimeout
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------

-- | Single peer-to-peer connection.
data Connection = Connection
  { connConfig :: !NetworkConfig,
    connState :: !ConnectionState,
    -- Timing
    connLastSendTime :: !MonoTime,
    connLastRecvTime :: !MonoTime,
    -- Subsystems
    connReliability :: !ReliableEndpoint,
    connChannels :: !(IM.IntMap Channel),
    connChannelPriority :: ![Int],
    connCongestion :: !CongestionController,
    connBandwidthUp :: !BandwidthTracker,
    connBandwidthDown :: !BandwidthTracker,
    -- ACK resolution: packet seq -> (chanId, chanSeq)
    connAckMap :: !(Map.Map Word16 (ChannelId, SequenceNum)),
    -- Per-channel outgoing queues
    connOutgoing :: !(IM.IntMap (Seq OutgoingMessage)),
    -- Send queue (ready to transmit)
    connSendQueue :: !(Seq OutgoingPacket),
    -- Disconnect tracking
    connDisconnectReason :: !(Maybe DisconnectReason),
    connDisconnectTime :: !(Maybe MonoTime),
    connDisconnectRetries :: !Int,
    -- Fragment reassembly
    connFragmentAssembler :: !FragmentAssembler,
    -- Message ID for outgoing fragments
    connNextMessageId :: !MessageId,
    -- Flags
    connPendingAck :: !Bool,
    connDataSentThisTick :: !Bool
  }

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a new connection in Disconnected state.
newConnection :: NetworkConfig -> MonoTime -> IO Connection
newConnection cfg now = do
  rel <- newReliableEndpoint (ncMaxSequenceDistance cfg)
  cong <-
    newCongestionController
      (ncCongestionMode cfg)
      (ncSendRate cfg)
      (ncCongestionBadLossThreshold cfg)
      (fromIntegral (msToNs (ncCongestionGoodRttThresholdMs cfg)))
      (fromIntegral (ncMtu cfg))
  bwUp <- newBandwidthTracker bandwidthWindowMs
  bwDown <- newBandwidthTracker bandwidthWindowMs
  let channels = buildChannels cfg
      priority = buildPriority cfg channels
      fragAsm = newFragmentAssembler (ncFragmentTimeoutMs cfg) (ncMaxReassemblyBufferSize cfg)
  pure
    Connection
      { connConfig = cfg,
        connState = Disconnected,
        connLastSendTime = now,
        connLastRecvTime = now,
        connReliability = rel,
        connChannels = channels,
        connChannelPriority = priority,
        connCongestion = cong,
        connBandwidthUp = bwUp,
        connBandwidthDown = bwDown,
        connAckMap = Map.empty,
        connOutgoing = IM.map (const Seq.empty) channels,
        connSendQueue = Seq.empty,
        connDisconnectReason = Nothing,
        connDisconnectTime = Nothing,
        connDisconnectRetries = 0,
        connFragmentAssembler = fragAsm,
        connNextMessageId = initialMessageId,
        connPendingAck = False,
        connDataSentThisTick = False
      }

buildChannels :: NetworkConfig -> IM.IntMap Channel
buildChannels cfg =
  let cfgs = ncChannelConfigs cfg
      defCfg = ncDefaultChannelConfig cfg
      maxChan = ncMaxChannels cfg
      indexed = zip [0 ..] (take maxChan (cfgs ++ repeat defCfg))
   in IM.fromList
        [ (i, newChannel cid cc)
        | (i, cc) <- indexed,
          Just cid <- [mkChannelId (fromIntegral i)]
        ]

buildPriority :: NetworkConfig -> IM.IntMap Channel -> [Int]
buildPriority _ channels =
  map fst $
    sortBy (\(_, a) (_, b) -> compare (Down (channelPriority a)) (Down (channelPriority b))) $
      IM.toList channels

-- ---------------------------------------------------------------------------
-- State machine
-- ---------------------------------------------------------------------------

-- | Transition Disconnected -> Connecting.
connect :: Connection -> Either ConnectionError Connection
connect conn
  | connState conn == Disconnected = Right conn {connState = Connecting}
  | otherwise = Left ErrAlreadyConnected

-- | Transition any -> Disconnecting.
disconnect :: DisconnectReason -> MonoTime -> Connection -> Connection
disconnect reason now conn =
  conn
    { connState = Disconnecting,
      connDisconnectReason = Just reason,
      connDisconnectTime = Just now,
      connDisconnectRetries = 0
    }

-- | Transition Connecting -> Connected.
markConnected :: MonoTime -> Connection -> Connection
markConnected now conn =
  conn
    { connState = Connected,
      connLastRecvTime = now,
      connLastSendTime = now
    }

-- ---------------------------------------------------------------------------
-- Send / Receive
-- ---------------------------------------------------------------------------

-- | Send a message on the given channel.  Queues for congestion-gated
-- emission during 'updateTick'.
sendMessage ::
  ChannelId ->
  ByteString ->
  MonoTime ->
  Connection ->
  Either ConnectionError Connection
sendMessage cid payload now conn
  | connState conn /= Connected = Left ErrNotConnected
  | otherwise =
      let idx = channelIdToInt cid
       in case IM.lookup idx (connChannels conn) of
            Nothing -> Left ErrInvalidChannel
            Just ch ->
              case channelSend payload now ch of
                Left err -> Left (ErrChannelSend err)
                Right (msg, updated) ->
                  let outQ = case IM.lookup idx (connOutgoing conn) of
                        Just q -> q |> msg
                        Nothing -> Seq.singleton msg
                   in Right
                        conn
                          { connChannels = IM.insert idx updated (connChannels conn),
                            connOutgoing = IM.insert idx outQ (connOutgoing conn)
                          }

-- | Drain delivered messages from a channel.
receiveMessages :: ChannelId -> Connection -> ([ByteString], Connection)
receiveMessages cid conn =
  let idx = channelIdToInt cid
   in case IM.lookup idx (connChannels conn) of
        Nothing -> ([], conn)
        Just ch ->
          let (msgs, updated) = channelReceive ch
           in (msgs, conn {connChannels = IM.insert idx updated (connChannels conn)})

-- | Route an incoming payload to the appropriate channel.
receiveIncomingPayload ::
  ChannelId ->
  SequenceNum ->
  ByteString ->
  MonoTime ->
  Connection ->
  Connection
receiveIncomingPayload cid seq_ payload now conn =
  let idx = channelIdToInt cid
   in case IM.lookup idx (connChannels conn) of
        Nothing -> conn
        Just ch ->
          let updated = onMessageReceived seq_ payload now ch
           in conn {connChannels = IM.insert idx updated (connChannels conn)}

-- ---------------------------------------------------------------------------
-- ACK resolution (pure)
-- ---------------------------------------------------------------------------

-- | Walk ack_seq + ack_bitfield against the ack map to find which
-- channel messages were acknowledged.  Returns resolved pairs and
-- the pruned map.
resolveChannelAcks ::
  Word16 ->
  Word32 ->
  Map.Map Word16 (ChannelId, SequenceNum) ->
  ([(ChannelId, SequenceNum)], Map.Map Word16 (ChannelId, SequenceNum))
resolveChannelAcks ackSeq ackBitfield ackMap =
  let -- Direct ack
      (directResult, map1) = case Map.lookup ackSeq ackMap of
        Just pair -> ([pair], Map.delete ackSeq ackMap)
        Nothing -> ([], ackMap)
      -- Bitfield walk
      (bitResults, finalMap) =
        foldr
          ( \i (acc, m) ->
              let seq_ = ackSeq - 1 - fromIntegral i
               in if testBit ackBitfield i
                    then case Map.lookup seq_ m of
                      Just pair -> (pair : acc, Map.delete seq_ m)
                      Nothing -> (acc, m)
                    else (acc, m)
          )
          ([], map1)
          [0 .. ackBitfieldBits - 1]
   in (directResult ++ bitResults, finalMap)

-- ---------------------------------------------------------------------------
-- Packet pipeline
-- ---------------------------------------------------------------------------

-- | Process an incoming packet header (dedup, ACK processing, congestion).
processIncomingHeader ::
  Word16 ->
  Word16 ->
  Word32 ->
  MonoTime ->
  Connection ->
  IO (Maybe Connection)
processIncomingHeader packetSeq ackSeq ackBitfield now conn = do
  -- 1. Dedup + ack state update
  mRel <- onPacketReceived (connReliability conn) packetSeq
  case mRel of
    Nothing -> pure Nothing -- duplicate
    Just rel -> do
      -- 2. Process ACKs (C hot path)
      (outcome, rel2) <- processIncomingAck rel ackSeq ackBitfield now

      -- 3. Resolve channel-level acks (pure)
      let (ackedPairs, prunedMap) = resolveChannelAcks ackSeq ackBitfield (connAckMap conn)

      -- 4. Acknowledge on channels (pure)
      let chans = foldl ackOnChannel (connChannels conn) ackedPairs

      -- 5. Feed congestion
      congestionOnAck (connCongestion conn) (aoAckedBytes outcome) packetSeq
      when (aoLostCount outcome > 0) $
        congestionOnLoss (connCongestion conn) (aoRetransmitSeq outcome) now

      -- 6. Record bandwidth
      bandwidthRecord (connBandwidthDown conn) (fromIntegral (aoAckedBytes outcome)) (unMonoTime now)

      pure $
        Just
          conn
            { connReliability = rel2,
              connChannels = chans,
              connAckMap = prunedMap,
              connLastRecvTime = now,
              connPendingAck = True
            }

-- | Acknowledge a message on the appropriate channel.
ackOnChannel :: IM.IntMap Channel -> (ChannelId, SequenceNum) -> IM.IntMap Channel
ackOnChannel chans (cid, chanSeq) =
  IM.adjust (acknowledgeMessage chanSeq) (channelIdToInt cid) chans

-- | Drain per-channel outgoing queues through congestion gating.
-- Wraps each message as an OutgoingPacket with a fresh packet sequence.
processChannelOutput :: MonoTime -> Connection -> IO Connection
processChannelOutput now conn = go conn (connChannelPriority conn)
  where
    go c [] = pure c
    go c (idx : rest) =
      case IM.lookup idx (connOutgoing c) of
        Nothing -> go c rest
        Just q -> drainQueue c idx q rest

    drainQueue c idx q rest =
      case Seq.viewl q of
        Seq.EmptyL -> go c rest
        msg Seq.:< remaining -> do
          canSend <- congestionCanSend (connCongestion c) (fromIntegral (payloadSize msg))
          if canSend
            then do
              let (packetSeq, rel) = allocateSeq (connReliability c)
                  (ackSeq, ackBits) = getAckInfo (connReliability c)
                  pkt =
                    OutgoingPacket
                      { opPacketType = Payload,
                        opSeq = packetSeq,
                        opAckSeq = ackSeq,
                        opAckBits = ackBits,
                        opPayload = omPayload msg
                      }

              -- Record in reliability if reliable
              rel2 <-
                if omReliable msg
                  then
                    onPacketSent rel packetSeq (omChannelId msg) (omChannelSeq msg) now (payloadSize msg)
                  else pure rel

              -- Record in congestion
              congestionOnSend (connCongestion c) (fromIntegral (payloadSize msg)) now

              -- Record bandwidth
              bandwidthRecord (connBandwidthUp c) (fromIntegral (payloadSize msg)) (unMonoTime now)

              -- Update ack map for reliable messages
              let newAckMap
                    | omReliable msg =
                        Map.insert (unSequenceNum packetSeq) (omChannelId msg, omChannelSeq msg) (connAckMap c)
                    | otherwise = connAckMap c

              let updated =
                    c
                      { connReliability = rel2,
                        connOutgoing = IM.insert idx remaining (connOutgoing c),
                        connSendQueue = connSendQueue c |> pkt,
                        connAckMap = newAckMap,
                        connLastSendTime = now,
                        connDataSentThisTick = True
                      }
              drainQueue updated idx remaining rest
            else go (c {connOutgoing = IM.insert idx (msg Seq.<| remaining) (connOutgoing c)}) rest

    payloadSize msg = BS.length (omPayload msg)

-- | Retransmit RTO-expired reliable messages.
processRetransmissions :: MonoTime -> Connection -> IO Connection
processRetransmissions now conn = do
  rtoNs <- getRtoNs (connReliability conn)
  let process c idx ch =
        let (retrans, updated) = getRetransmitMessages now (fromIntegral rtoNs) ch
            outQ = case IM.lookup idx (connOutgoing c) of
              Just q -> foldl (|>) q retrans
              Nothing -> Seq.fromList retrans
         in c
              { connChannels = IM.insert idx updated (connChannels c),
                connOutgoing = IM.insert idx outQ (connOutgoing c)
              }
  pure $ IM.foldlWithKey' process conn (connChannels conn)

-- | Pop all queued packets for transmission.
drainSendQueue :: Connection -> ([OutgoingPacket], Connection)
drainSendQueue conn =
  let pkts = foldr (:) [] (connSendQueue conn)
   in (pkts, conn {connSendQueue = Seq.empty})

-- ---------------------------------------------------------------------------
-- Per-tick update
-- ---------------------------------------------------------------------------

-- | Main per-frame update.  Returns 'Left ErrTimeout' if the
-- connection has timed out.
updateTick :: MonoTime -> Connection -> IO (Either ConnectionError Connection)
updateTick now conn =
  case connState conn of
    Disconnected -> pure (Right conn)
    Connecting -> pure (Right conn)
    Connected -> updateConnected now conn
    Disconnecting -> Right <$> updateDisconnecting now conn

updateConnected :: MonoTime -> Connection -> IO (Either ConnectionError Connection)
updateConnected now conn = do
  -- Timeout check
  let elapsed = diffNs (connLastRecvTime conn) now
      timeout = msToNs (ncConnectionTimeoutMs (connConfig conn))
  if elapsed >= timeout
    then pure (Left ErrTimeout)
    else do
      -- Congestion tick
      lossPct <- packetLossPercent (connReliability conn)
      srttNs <- getSrttNs (connReliability conn)
      let lastTick = connLastSendTime conn
          dtSec = fromIntegral (diffNs lastTick now) / 1e9 :: Double
      congestionTick (connCongestion conn) dtSec lossPct srttNs now

      -- Channel updates (ordered buffer flush, dedup cleanup)
      let chans = IM.map (channelUpdate now) (connChannels conn)

      -- Fragment reassembly timeout cleanup
      let fragAsm = assemblerUpdate now (connFragmentAssembler conn)

      -- Retransmissions
      conn2 <- processRetransmissions now (conn {connChannels = chans, connFragmentAssembler = fragAsm})

      -- Congestion-gated output
      conn3 <- processChannelOutput now conn2

      -- Keepalive
      let kaElapsed = diffNs (connLastSendTime conn3) now
          kaInterval = msToNs (ncKeepaliveIntervalMs (connConfig conn3))
      conn4 <-
        if kaElapsed >= kaInterval
          then pure (enqueueKeepalive conn3)
          else pure conn3

      -- Ack-only if we have pending ack and sent no data
      let conn5
            | connPendingAck conn4 && not (connDataSentThisTick conn4) =
                enqueueKeepalive conn4
            | otherwise = conn4

      pure $
        Right
          conn5
            { connPendingAck = False,
              connDataSentThisTick = False
            }

updateDisconnecting :: MonoTime -> Connection -> IO Connection
updateDisconnecting now conn =
  case connDisconnectTime conn of
    Nothing -> pure conn
    Just discTime -> do
      let elapsed = diffNs discTime now
          retryTimeout = msToNs (ncDisconnectRetryTimeoutMs (connConfig conn))
          maxRetries = ncDisconnectRetries (connConfig conn)
      if connDisconnectRetries conn >= maxRetries
        then
          pure
            conn
              { connState = Disconnected,
                connDisconnectTime = Nothing
              }
        else
          if elapsed >= retryTimeout * fromIntegral (connDisconnectRetries conn + 1)
            then
              pure $
                enqueueDisconnect
                  conn
                    { connDisconnectRetries = connDisconnectRetries conn + 1
                    }
            else pure conn

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

enqueueKeepalive :: Connection -> Connection
enqueueKeepalive conn =
  let (ackSeq, ackBits) = getAckInfo (connReliability conn)
      (seq_, rel) = allocateSeq (connReliability conn)
      pkt =
        OutgoingPacket
          { opPacketType = Keepalive,
            opSeq = seq_,
            opAckSeq = ackSeq,
            opAckBits = ackBits,
            opPayload = mempty
          }
   in conn
        { connReliability = rel,
          connSendQueue = connSendQueue conn |> pkt,
          connDataSentThisTick = True
        }

enqueueDisconnect :: Connection -> Connection
enqueueDisconnect conn =
  let (ackSeq, ackBits) = getAckInfo (connReliability conn)
      (seq_, rel) = allocateSeq (connReliability conn)
      pkt =
        OutgoingPacket
          { opPacketType = Disconnect,
            opSeq = seq_,
            opAckSeq = ackSeq,
            opAckBits = ackBits,
            opPayload = encodeDisconnectReason (connDisconnectReason conn)
          }
   in conn
        { connReliability = rel,
          connSendQueue = connSendQueue conn |> pkt,
          connDataSentThisTick = True
        }

encodeDisconnectReason :: Maybe DisconnectReason -> ByteString
encodeDisconnectReason Nothing = BS.singleton 0
encodeDisconnectReason (Just reason) = BS.singleton (disconnectReasonCode reason)

-- ---------------------------------------------------------------------------
-- Time tracking
-- ---------------------------------------------------------------------------

-- | Update last recv timestamp.
touchRecvTime :: MonoTime -> Connection -> Connection
touchRecvTime now conn = conn {connLastRecvTime = now}

-- | Update last send timestamp.
touchSendTime :: MonoTime -> Connection -> Connection
touchSendTime now conn = conn {connLastSendTime = now}

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Current connection state.
connectionState :: Connection -> ConnectionState
connectionState = connState

-- | Is the connection in Connected state?
isConnected :: Connection -> Bool
isConnected conn = connState conn == Connected

-- | Number of channels.
channelCount :: Connection -> Int
channelCount = IM.size . connChannels

-- ---------------------------------------------------------------------------
-- Reset
-- ---------------------------------------------------------------------------

-- | Reset transport metrics (new network path).
resetTransportMetrics :: Connection -> IO Connection
resetTransportMetrics conn = do
  rel <- resetMetrics (connReliability conn)
  pure conn {connReliability = rel}

-- ---------------------------------------------------------------------------
-- Fragment processing
-- ---------------------------------------------------------------------------

-- | Process an incoming fragment through the reassembly pipeline.
-- Returns the completed reassembled message when all fragments arrive.
processFragment :: ByteString -> MonoTime -> Connection -> (Maybe ByteString, Connection)
processFragment payload now conn =
  let (result, updated) = onFragmentReceived payload now (connFragmentAssembler conn)
   in (result, conn {connFragmentAssembler = updated})

-- | Allocate the next message ID for outgoing fragmented messages.
allocateMessageId :: Connection -> (MessageId, Connection)
allocateMessageId conn =
  let mid = connNextMessageId conn
   in (mid, conn {connNextMessageId = nextMessageId mid})
