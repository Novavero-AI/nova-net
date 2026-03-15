-- |
-- Module      : NovaNet.Peer
-- Description : Multi-peer networking — the public API
--
-- Composes Connection, Channel, Reliability, Congestion, Fragment,
-- Security, and Stats into a multi-peer networking stack.  Manages
-- handshake, migration, encryption, and socket I/O.
module NovaNet.Peer
  ( -- * Core state
    NetPeer,

    -- * Construction
    newPeerState,

    -- * Connection management
    peerConnect,
    peerDisconnect,

    -- * Send
    peerSend,
    peerBroadcast,

    -- * Processing
    IncomingPacket (..),
    RawPacket (..),
    PeerResult (..),
    peerProcess,

    -- * Polymorphic helpers
    peerRecvAllM,
    peerSendAllM,

    -- * Queries
    peerCount,
    peerIsConnected,
    peerConnectedIds,

    -- * Errors
    ConnectionError (..),
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import Data.Foldable (toList)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.ForeignPtr (withForeignPtr)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, plusPtr)
import Network.Socket (SockAddr)
import NovaNet.Class
import NovaNet.Config
import NovaNet.Connection
  ( Connection,
    ConnectionError (..),
    OutgoingPacket (..),
    connectionState,
    disconnect,
    drainSendQueue,
    isConnected,
    processChannelOutput,
    processIncomingHeader,
    receiveIncomingPayload,
    receiveMessages,
    sendMessage,
    updateTick,
  )
import qualified NovaNet.Connection as Conn
import NovaNet.FFI.CRC32C (crc32cAppend, crc32cSize, crc32cValidate)
import NovaNet.FFI.Packet (packetHeaderSize, packetRead, packetWrite)
import NovaNet.FFI.Random (randomBytes, randomWord64)
import NovaNet.Fragment (splitMessage)
import NovaNet.Peer.Handshake
import NovaNet.Peer.Migration (findMigrationCandidate, migrateConnection)
import NovaNet.Peer.Protocol
import NovaNet.Security (RateLimiter, newRateLimiter)
import NovaNet.Stats (SocketStats, defaultSocketStats, recordCrcDrop, recordSocketRecv)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | An incoming packet from the network.
data IncomingPacket = IncomingPacket
  { ipSource :: !PeerId,
    ipData :: !ByteString
  }
  deriving (Show)

-- | A raw packet ready to be sent on the wire.
data RawPacket = RawPacket
  { rpDest :: !PeerId,
    rpData :: !ByteString
  }
  deriving (Show)

-- | Result of processing one tick.
data PeerResult = PeerResult
  { prEvents :: ![PeerEvent],
    prOutgoing :: ![RawPacket],
    prPeer :: !NetPeer
  }

-- | The main peer state.
data NetPeer = NetPeer
  { npConnections :: !(Map.Map PeerId Connection),
    npPending :: !(Map.Map PeerId PendingConnection),
    npConfig :: !NetworkConfig,
    npRateLimiter :: !RateLimiter,
    npCookieSecret :: !ByteString,
    npMigrationCooldowns :: !(Map.Map Word64 MonoTime),
    npSendQueue :: !(Seq RawPacket),
    npSocketStats :: !SocketStats,
    npLocalAddr :: !SockAddr
  }

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a new peer state. Generates a random cookie secret.
newPeerState :: SockAddr -> NetworkConfig -> MonoTime -> IO NetPeer
newPeerState localAddr cfg now = do
  secret <- randomBytes cookieSecretSize
  pure
    NetPeer
      { npConnections = Map.empty,
        npPending = Map.empty,
        npConfig = cfg,
        npRateLimiter = newRateLimiter (ncRateLimitPerSecond cfg) now,
        npCookieSecret = secret,
        npMigrationCooldowns = Map.empty,
        npSendQueue = Seq.empty,
        npSocketStats = defaultSocketStats,
        npLocalAddr = localAddr
      }

-- ---------------------------------------------------------------------------
-- Connection management
-- ---------------------------------------------------------------------------

-- | Initiate a connection to a remote peer.
-- Queues a ConnectionRequest with the protocol ID (#26).
peerConnect :: PeerId -> MonoTime -> NetPeer -> IO NetPeer
peerConnect peerId now peer
  | Map.member peerId (npConnections peer) = pure peer
  | Map.member peerId (npPending peer) = pure peer
  | otherwise = do
      clientSalt <- randomWord64
      reqPacket <- serializeHandshakePacket ConnectionRequest (encodeProtocolId (ncProtocolId (npConfig peer)))
      let pkt = RawPacket peerId reqPacket
          pc =
            PendingConnection
              { pcDirection = Outbound,
                pcServerSalt = 0,
                pcClientSalt = clientSalt,
                pcCreatedAt = now,
                pcRetryCount = 0,
                pcLastRetry = now
              }
      pure
        peer
          { npPending = Map.insert peerId pc (npPending peer),
            npSendQueue = npSendQueue peer |> pkt
          }

-- | Disconnect from a remote peer.
peerDisconnect :: PeerId -> MonoTime -> NetPeer -> NetPeer
peerDisconnect peerId now peer =
  case Map.lookup peerId (npConnections peer) of
    Just conn ->
      let disconnected = disconnect ReasonRequested now conn
       in peer {npConnections = Map.insert peerId disconnected (npConnections peer)}
    Nothing ->
      peer {npPending = Map.delete peerId (npPending peer)}

-- ---------------------------------------------------------------------------
-- Send
-- ---------------------------------------------------------------------------

-- | Send a message to a connected peer on the given channel.
peerSend :: PeerId -> ChannelId -> ByteString -> MonoTime -> NetPeer -> Either ConnectionError NetPeer
peerSend peerId cid payload now peer =
  case Map.lookup peerId (npConnections peer) of
    Nothing -> Left ErrNotConnected
    Just conn ->
      let cfg = npConfig peer
          threshold = ncFragmentThreshold cfg
       in if BS.length payload <= threshold
            then case sendMessage cid payload now conn of
              Left err -> Left err
              Right updated ->
                Right peer {npConnections = Map.insert peerId updated (npConnections peer)}
            else sendFragmented peerId cid payload now conn cfg peer

-- | Send a large message by fragmenting it.
sendFragmented ::
  PeerId ->
  ChannelId ->
  ByteString ->
  MonoTime ->
  Connection ->
  NetworkConfig ->
  NetPeer ->
  Either ConnectionError NetPeer
sendFragmented peerId cid payload now conn cfg peer =
  let mtuSize = ncMtu cfg
      overhead = packetHeaderSize + payloadHeaderSize + fragHeaderSizeConst
      maxFragPayload = max 1 (mtuSize - overhead)
      (mid, conn2) = Conn.allocateMessageId conn
   in case splitMessage mid payload maxFragPayload of
        Left _ -> Left ErrInvalidChannel
        Right frags ->
          case foldlEither (\c frag -> sendMessage cid frag now c) conn2 frags of
            Left err -> Left err
            Right final ->
              Right peer {npConnections = Map.insert peerId final (npConnections peer)}

-- | Broadcast a message to all connected peers (optionally excluding one).
peerBroadcast :: ChannelId -> ByteString -> Maybe PeerId -> MonoTime -> NetPeer -> NetPeer
peerBroadcast cid payload exclude now peer =
  let targets = case exclude of
        Nothing -> Map.keys (npConnections peer)
        Just ex -> filter (/= ex) (Map.keys (npConnections peer))
      sendOne p pid = case peerSend pid cid payload now p of
        Left _ -> p
        Right updated -> updated
   in foldl sendOne peer targets

-- ---------------------------------------------------------------------------
-- Processing
-- ---------------------------------------------------------------------------

-- | Process incoming packets and update all connections.
-- Returns events, outgoing packets, and updated state.
peerProcess :: MonoTime -> [IncomingPacket] -> NetPeer -> IO PeerResult
peerProcess now incoming peer = do
  -- 1. Process incoming packets
  (peer2, events1) <- processIncoming now incoming peer

  -- 2. Update all connections (timeout/congestion/retransmit/keepalive)
  (peer3, events2) <- updateAllConnections now peer2

  -- 3. Drain connection send queues (serialize + CRC)
  peer4 <- drainAllConnections now peer3

  -- 4. Retry pending outbound connections
  let (pending2, retryActs) = retryPendingConnections now (npConfig peer4) (npPending peer4)
  retryPkts <- mapM serializeAction retryActs

  -- 5. Cleanup expired pending connections
  let (pending3, events3) = cleanupPending now (npConfig peer4) pending2

  let sq = foldl (|>) (npSendQueue peer4) retryPkts
  let peer5 = peer4 {npPending = pending3, npSendQueue = sq}

  -- 6. Drain send queue
  let (outgoing, peer6) = drainPeerSendQueue peer5

  -- 7. Evict expired migration cooldowns
  let cleanedCooldowns =
        Map.filter (\t -> diffNs t now < migrationCooldownNs) (npMigrationCooldowns peer6)
      peer7 = peer6 {npMigrationCooldowns = cleanedCooldowns}

  pure
    PeerResult
      { prEvents = events1 ++ events2 ++ events3,
        prOutgoing = outgoing,
        prPeer = peer7
      }

-- ---------------------------------------------------------------------------
-- Polymorphic helpers
-- ---------------------------------------------------------------------------

-- | Receive all available packets from the network.
peerRecvAllM :: (MonadNetwork m) => m [IncomingPacket]
peerRecvAllM = go []
  where
    go acc = do
      result <- netRecv
      case result of
        Left _ -> pure (reverse acc)
        Right Nothing -> pure (reverse acc)
        Right (Just (dat, addr)) ->
          go (IncomingPacket (PeerId addr) dat : acc)

-- | Send all outgoing packets to the network.
peerSendAllM :: (MonadNetwork m) => [RawPacket] -> m ()
peerSendAllM = mapM_ $ \rp ->
  netSend (unPeerId (rpDest rp)) (rpData rp)

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Number of active connections.
peerCount :: NetPeer -> Int
peerCount = Map.size . npConnections
{-# INLINE peerCount #-}

-- | Is the given peer connected?
peerIsConnected :: PeerId -> NetPeer -> Bool
peerIsConnected pid peer =
  maybe False isConnected (Map.lookup pid (npConnections peer))
{-# INLINE peerIsConnected #-}

-- | List of connected peer IDs.
peerConnectedIds :: NetPeer -> [PeerId]
peerConnectedIds = Map.keys . Map.filter isConnected . npConnections

-- ---------------------------------------------------------------------------
-- Internal constants
-- ---------------------------------------------------------------------------

-- | Size of the payload header byte.
payloadHeaderSize :: Int
payloadHeaderSize = 1

-- | Size of fragment header.
fragHeaderSizeConst :: Int
fragHeaderSizeConst = 6

-- ---------------------------------------------------------------------------
-- Internal: incoming packet dispatch
-- ---------------------------------------------------------------------------

processIncoming :: MonoTime -> [IncomingPacket] -> NetPeer -> IO (NetPeer, [PeerEvent])
processIncoming now packets peer = go peer [] packets
  where
    go p evts [] = pure (p, reverse evts)
    go p evts (pkt : rest) = do
      (p2, newEvts) <- processOnePacket now pkt p
      go p2 (reverse newEvts ++ evts) rest

processOnePacket :: MonoTime -> IncomingPacket -> NetPeer -> IO (NetPeer, [PeerEvent])
processOnePacket now (IncomingPacket srcPeer rawData) peer = do
  -- CRC validation
  mPayload <- validateCrc rawData
  case mPayload of
    Nothing ->
      pure (peer {npSocketStats = recordCrcDrop (npSocketStats peer)}, [])
    Just payload -> do
      let stats = recordSocketRecv (BS.length rawData) (npSocketStats peer)
      -- Parse packet header
      mHeader <- parseHeader payload
      case mHeader of
        Nothing -> pure (peer {npSocketStats = stats}, [])
        Just (pktType, pktSeq, pktAck, pktAckBits, pktPayload) ->
          dispatchPacket
            now
            srcPeer
            pktType
            pktSeq
            pktAck
            pktAckBits
            pktPayload
            (peer {npSocketStats = stats})

-- | Dispatch based on packet type.
dispatchPacket ::
  MonoTime ->
  PeerId ->
  PacketType ->
  Word16 ->
  Word16 ->
  Word32 ->
  ByteString ->
  NetPeer ->
  IO (NetPeer, [PeerEvent])
dispatchPacket now srcPeer pktType pktSeq pktAck pktAckBits pktPayload peer =
  case pktType of
    ConnectionRequest -> do
      serverSalt <- randomWord64
      let (pending2, rl2, acts, evts) =
            handleConnectionRequest
              srcPeer
              pktPayload
              serverSalt
              now
              (npConfig peer)
              (npCookieSecret peer)
              (npConnections peer)
              (npPending peer)
              (npRateLimiter peer)
      actPkts <- mapM serializeAction acts
      let sq = foldl (|>) (npSendQueue peer) actPkts
      pure (peer {npPending = pending2, npRateLimiter = rl2, npSendQueue = sq}, evts)
    ConnectionChallenge ->
      let (pending2, acts) =
            handleConnectionChallenge srcPeer pktPayload (npPending peer)
       in do
            actPkts <- mapM serializeAction acts
            let sq = foldl (|>) (npSendQueue peer) actPkts
            pure (peer {npPending = pending2, npSendQueue = sq}, [])
    ConnectionResponse -> do
      (conns2, pending2, acts, evts) <-
        handleConnectionResponse
          srcPeer
          pktPayload
          now
          (npConfig peer)
          (npCookieSecret peer)
          (npConnections peer)
          (npPending peer)
      actPkts <- mapM serializeAction acts
      let sq = foldl (|>) (npSendQueue peer) actPkts
      pure (peer {npConnections = conns2, npPending = pending2, npSendQueue = sq}, evts)
    ConnectionAccepted -> do
      (conns2, pending2, evts) <-
        handleConnectionAccepted srcPeer now (npConfig peer) (npConnections peer) (npPending peer)
      pure (peer {npConnections = conns2, npPending = pending2}, evts)
    ConnectionDenied ->
      let (pending2, evts) = handleConnectionDenied srcPeer pktPayload (npPending peer)
       in pure (peer {npPending = pending2}, evts)
    Disconnect ->
      let (conns2, evts) = handleDisconnect srcPeer pktPayload (npConnections peer)
       in pure (peer {npConnections = conns2}, evts)
    Payload -> processDataPacket now srcPeer pktSeq pktAck pktAckBits pktPayload peer
    Keepalive -> processDataPacket now srcPeer pktSeq pktAck pktAckBits pktPayload peer

-- | Process a post-handshake data packet (Payload or Keepalive).
processDataPacket ::
  MonoTime ->
  PeerId ->
  Word16 ->
  Word16 ->
  Word32 ->
  ByteString ->
  NetPeer ->
  IO (NetPeer, [PeerEvent])
processDataPacket now srcPeer pktSeq pktAck pktAckBits pktPayload peer =
  case Map.lookup srcPeer (npConnections peer) of
    Just conn -> do
      mConn <- processIncomingHeader pktSeq pktAck pktAckBits now conn
      case mConn of
        Nothing -> pure (peer, [])
        Just conn2 -> do
          let (conn3, msgEvents) =
                if BS.null pktPayload
                  then (conn2, [])
                  else processPayloadData srcPeer pktPayload now conn2
          pure
            ( peer {npConnections = Map.insert srcPeer conn3 (npConnections peer)},
              msgEvents
            )
    Nothing ->
      case findMigrationCandidate pktSeq srcPeer (npConfig peer) (npConnections peer) (npMigrationCooldowns peer) now of
        Just oldPeer -> do
          (conns2, cooldowns2, migEvts) <-
            migrateConnection oldPeer srcPeer now (npConnections peer) (npMigrationCooldowns peer)
          pure (peer {npConnections = conns2, npMigrationCooldowns = cooldowns2}, migEvts)
        Nothing -> pure (peer, [])

-- | Process payload data: decode payload header, route to channel.
processPayloadData :: PeerId -> ByteString -> MonoTime -> Connection -> (Connection, [PeerEvent])
processPayloadData srcPeer payload now conn =
  case BS.uncons payload of
    Nothing -> (conn, [])
    Just (hdrByte, rest) ->
      case decodePayloadHeader hdrByte of
        Nothing -> (conn, [])
        Just (cid, isFragment) ->
          if isFragment
            then processFragmentData srcPeer rest now conn
            else processDirectMessage srcPeer cid rest now conn

-- | Process a direct (non-fragmented) message.
processDirectMessage :: PeerId -> ChannelId -> ByteString -> MonoTime -> Connection -> (Connection, [PeerEvent])
processDirectMessage srcPeer cid rest now conn =
  case decodeChannelSeq rest of
    Nothing -> (conn, [])
    Just chanSeq ->
      let msgData = BS.drop 2 rest
          conn2 = receiveIncomingPayload cid chanSeq msgData now conn
          (msgs, conn3) = receiveMessages cid conn2
          events = map (PeerMessage srcPeer cid) msgs
       in (conn3, events)

-- | Process a fragmented message through reassembly.
processFragmentData :: PeerId -> ByteString -> MonoTime -> Connection -> (Connection, [PeerEvent])
processFragmentData srcPeer fragPayload now conn =
  let (mComplete, conn2) = Conn.processFragment fragPayload now conn
   in case mComplete of
        Nothing -> (conn2, [])
        Just assembled ->
          case BS.uncons assembled of
            Nothing -> (conn2, [])
            Just (innerHdr, innerRest) ->
              case decodePayloadHeader innerHdr of
                Nothing -> (conn2, [])
                Just (innerCid, _) ->
                  processDirectMessage srcPeer innerCid innerRest now conn2

-- ---------------------------------------------------------------------------
-- Internal: update all connections
-- ---------------------------------------------------------------------------

updateAllConnections :: MonoTime -> NetPeer -> IO (NetPeer, [PeerEvent])
updateAllConnections now peer = do
  let connList = Map.toList (npConnections peer)
  go Map.empty [] connList
  where
    go acc evts [] = pure (peer {npConnections = acc}, reverse evts)
    go acc evts ((pid, conn) : rest) = do
      result <- updateTick now conn
      case result of
        Left ErrTimeout ->
          go acc (PeerDisconnected pid ReasonTimeout : evts) rest
        Left _ ->
          go (Map.insert pid conn acc) evts rest
        Right updated ->
          if connectionState updated == Disconnected && connectionState conn == Disconnecting
            then
              let reason = fromMaybe ReasonRequested (Conn.connDisconnectReason updated)
               in go acc (PeerDisconnected pid reason : evts) rest
            else go (Map.insert pid updated acc) evts rest

-- ---------------------------------------------------------------------------
-- Internal: drain connection send queues
-- ---------------------------------------------------------------------------

drainAllConnections :: MonoTime -> NetPeer -> IO NetPeer
drainAllConnections now peer = do
  let connList = Map.toList (npConnections peer)
  go Map.empty (npSendQueue peer) connList
  where
    go acc sq [] = pure peer {npConnections = acc, npSendQueue = sq}
    go acc sq ((pid, conn) : rest) = do
      conn2 <- processChannelOutput now conn
      let (pkts, conn3) = drainSendQueue conn2
      serialized <- mapM (serializeOutgoing pid) pkts
      let sq2 = foldl (|>) sq serialized
      go (Map.insert pid conn3 acc) sq2 rest

-- | Serialize an outgoing packet: header + payload + CRC.
serializeOutgoing :: PeerId -> OutgoingPacket -> IO RawPacket
serializeOutgoing pid pkt = do
  let payloadLen = BS.length (opPayload pkt)
      totalLen = packetHeaderSize + payloadLen + crc32cSize
  bs <- BSI.create totalLen $ \buf -> do
    -- Write packet header
    _ <- packetWrite (packetTypeToWord8 (opPacketType pkt)) (unSequenceNum (opSeq pkt)) (opAckSeq pkt) (opAckBits pkt) buf
    -- Copy payload
    let payloadDst = buf `plusPtr` packetHeaderSize
    withBS (opPayload pkt) $ \src srcLen ->
      copyBytes payloadDst src srcLen
    -- Append CRC
    _ <- crc32cAppend buf (packetHeaderSize + payloadLen)
    pure ()
  pure (RawPacket pid bs)

-- | Drain the peer-level send queue.
drainPeerSendQueue :: NetPeer -> ([RawPacket], NetPeer)
drainPeerSendQueue peer =
  let pkts = toList (npSendQueue peer)
   in (pkts, peer {npSendQueue = Seq.empty})

-- ---------------------------------------------------------------------------
-- Internal: serialization helpers
-- ---------------------------------------------------------------------------

-- | Serialize a HandshakeAction to a wire packet (header + payload + CRC).
-- Handshake packets use seq=0, ack=0, ackBits=0.
serializeAction :: HandshakeAction -> IO RawPacket
serializeAction (HandshakeAction dest pktType payload) = do
  wireBytes <- serializeHandshakePacket pktType payload
  pure (RawPacket dest wireBytes)

-- | Serialize a handshake packet: header + payload + CRC.
serializeHandshakePacket :: PacketType -> ByteString -> IO ByteString
serializeHandshakePacket pktType payload = do
  let payloadLen = BS.length payload
      totalLen = packetHeaderSize + payloadLen + crc32cSize
  BSI.create totalLen $ \buf -> do
    _ <- packetWrite (packetTypeToWord8 pktType) 0 0 0 buf
    let payloadDst = buf `plusPtr` packetHeaderSize
    withBS payload $ \src srcLen ->
      copyBytes payloadDst src srcLen
    _ <- crc32cAppend buf (packetHeaderSize + payloadLen)
    pure ()

-- | Validate CRC32C and return the payload (without CRC).
validateCrc :: ByteString -> IO (Maybe ByteString)
validateCrc bs
  | BS.length bs < packetHeaderSize + crc32cSize = pure Nothing
  | otherwise =
      withBS bs $ \ptr len -> do
        validLen <- crc32cValidate ptr len
        if validLen == 0
          then pure Nothing
          else pure (Just (BS.take validLen bs))

-- | Parse packet header from a ByteString.
parseHeader :: ByteString -> IO (Maybe (PacketType, Word16, Word16, Word32, ByteString))
parseHeader bs
  | BS.length bs < packetHeaderSize = pure Nothing
  | otherwise =
      withBS bs $ \ptr len -> do
        mResult <- packetRead ptr len
        case mResult of
          Nothing -> pure Nothing
          Just (ptByte, pktSeq, pktAck, pktAckBits) ->
            case packetTypeFromWord8 ptByte of
              Nothing -> pure Nothing
              Just pktType ->
                pure (Just (pktType, pktSeq, pktAck, pktAckBits, BS.drop packetHeaderSize bs))

-- | Use a ByteString's internal buffer.
withBS :: ByteString -> (Ptr Word8 -> Int -> IO a) -> IO a
withBS bs f =
  let (fptr, off, len) = BSI.toForeignPtr bs
   in withForeignPtr fptr $ \ptr -> f (ptr `plusPtr` off) len

-- | Left-biased fold that short-circuits on error.
foldlEither :: (b -> a -> Either e b) -> b -> [a] -> Either e b
foldlEither _ acc [] = Right acc
foldlEither f acc (x : xs) = case f acc x of
  Left err -> Left err
  Right acc2 -> foldlEither f acc2 xs
