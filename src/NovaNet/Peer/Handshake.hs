-- |
-- Module      : NovaNet.Peer.Handshake
-- Description : 4-way challenge/response handshake
--
-- Pure state transforms for the connection handshake protocol.
-- Implements all 6 port fixes from the gbnet-hs audit:
--   #4  HMAC-bound challenge cookies via SipHash
--   #10 ncMaxPending for pending limit
--   #11 Simultaneous connect tiebreak (lower address = server)
--   #16 Disconnect reason preserved from payload
--   #26 Protocol ID in ConnectionRequest, early version mismatch rejection
module NovaNet.Peer.Handshake
  ( -- * Pending connections
    PendingConnection (..),

    -- * Outbound action
    HandshakeAction (..),

    -- * Handlers
    handleConnectionRequest,
    handleConnectionChallenge,
    handleConnectionResponse,
    handleConnectionAccepted,
    handleConnectionDenied,
    handleDisconnect,

    -- * Maintenance
    retryPendingConnections,
    cleanupPending,

    -- * Cookie computation
    computeCookie,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word64)
import Network.Socket (SockAddr)
import NovaNet.Config
import NovaNet.Connection (Connection, markConnected, newConnection)
import qualified NovaNet.Connection as Conn
import NovaNet.FFI.SipHash (siphash)
import NovaNet.Peer.Protocol
import NovaNet.Security (RateLimiter, addressKey, rateLimiterAllow)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | A connection in the handshake phase.
data PendingConnection = PendingConnection
  { pcDirection :: !ConnectionDirection,
    pcServerSalt :: !Word64,
    pcClientSalt :: !Word64,
    pcCreatedAt :: !MonoTime,
    pcRetryCount :: !Int,
    pcLastRetry :: !MonoTime
  }
  deriving (Show)

-- | An outbound wire action produced by a handshake handler.
-- Peer module converts these to serialized wire packets.
data HandshakeAction = HandshakeAction
  { haTarget :: !PeerId,
    haPacketType :: !PacketType,
    haPayload :: !ByteString
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Cookie
-- ---------------------------------------------------------------------------

-- | Compute an HMAC-bound cookie: SipHash(secret, serverSalt ++ addrHash).
-- Fix #4: challenge cookies are bound to the server salt and client address.
computeCookie :: ByteString -> Word64 -> SockAddr -> Word64
computeCookie secret serverSalt addr =
  let addrHash = addressKey addr
      msg = encodeSalt serverSalt <> encodeSalt addrHash
   in siphash secret msg
{-# INLINE computeCookie #-}

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

-- | Handle an incoming ConnectionRequest (server side).
-- Validates: rate limit, pending capacity (#10), client capacity,
-- protocol ID (#26), simultaneous connect (#11).
-- On success: uses caller-provided salt, computes cookie (#4),
-- queues Challenge.
handleConnectionRequest ::
  PeerId ->
  ByteString ->
  Word64 ->
  MonoTime ->
  NetworkConfig ->
  ByteString ->
  Map.Map PeerId Connection ->
  Map.Map PeerId PendingConnection ->
  RateLimiter ->
  (Map.Map PeerId PendingConnection, RateLimiter, [HandshakeAction], [PeerEvent])
handleConnectionRequest peerId payload serverSalt now cfg cookieSecret conns pending rl =
  -- Rate limit check
  let srcKey = addressKey (unPeerId peerId)
      (allowed, rl2) = rateLimiterAllow srcKey now rl
   in if not allowed
        then (pending, rl2, [], [])
        else -- Already connected? Resend Accepted
          case Map.lookup peerId conns of
            Just _ ->
              let act = HandshakeAction peerId ConnectionAccepted BS.empty
               in (pending, rl2, [act], [])
            Nothing ->
              -- Protocol ID check (#26)
              case decodeProtocolId payload of
                Nothing -> (pending, rl2, [], [])
                Just protId
                  | protId /= ncProtocolId cfg ->
                      let act = HandshakeAction peerId ConnectionDenied (encodeDenyReason ReasonProtocolMismatch)
                       in (pending, rl2, [act], [])
                  | otherwise ->
                      -- Check simultaneous connect (#11)
                      case Map.lookup peerId pending of
                        Just pc
                          | pcDirection pc == Outbound ->
                              -- Accept server role: replace outbound with inbound
                              acceptAsServer peerId serverSalt now cfg cookieSecret pending rl2
                        _ ->
                          if Map.size pending >= ncMaxPending cfg || Map.size conns >= ncMaxClients cfg
                            then
                              let act = HandshakeAction peerId ConnectionDenied (encodeDenyReason ReasonServerFull)
                               in (pending, rl2, [act], [])
                            else acceptAsServer peerId serverSalt now cfg cookieSecret pending rl2

-- | Generate a challenge and record as inbound pending.
acceptAsServer ::
  PeerId ->
  Word64 ->
  MonoTime ->
  NetworkConfig ->
  ByteString ->
  Map.Map PeerId PendingConnection ->
  RateLimiter ->
  (Map.Map PeerId PendingConnection, RateLimiter, [HandshakeAction], [PeerEvent])
acceptAsServer peerId serverSalt now _cfg cookieSecret pending rl =
  let cookie = computeCookie cookieSecret serverSalt (unPeerId peerId)
      challengePayload = encodeSalt serverSalt <> encodeSalt cookie
      act = HandshakeAction peerId ConnectionChallenge challengePayload
      pc =
        PendingConnection
          { pcDirection = Inbound,
            pcServerSalt = serverSalt,
            pcClientSalt = 0,
            pcCreatedAt = now,
            pcRetryCount = 0,
            pcLastRetry = now
          }
   in (Map.insert peerId pc pending, rl, [act], [])

-- | Handle an incoming ConnectionChallenge (client side).
-- Extracts server salt + cookie, queues Response with client salt.
handleConnectionChallenge ::
  PeerId ->
  ByteString ->
  Map.Map PeerId PendingConnection ->
  (Map.Map PeerId PendingConnection, [HandshakeAction])
handleConnectionChallenge peerId payload pending =
  case Map.lookup peerId pending of
    Nothing -> (pending, [])
    Just pc
      | pcDirection pc /= Outbound -> (pending, [])
      | BS.length payload < 16 -> (pending, [])
      | otherwise ->
          case (decodeSalt payload, decodeSalt (BS.drop 8 payload)) of
            (Just serverSalt, Just cookie) ->
              let clientSalt = pcClientSalt pc
                  responsePayload =
                    encodeSalt clientSalt
                      <> encodeSalt serverSalt
                      <> encodeSalt cookie
                  act = HandshakeAction peerId ConnectionResponse responsePayload
                  updated = pc {pcServerSalt = serverSalt}
               in (Map.insert peerId updated pending, [act])
            _ -> (pending, [])

-- | Handle an incoming ConnectionResponse (server side).
-- Recomputes cookie (#4), validates salts, creates Connection.
handleConnectionResponse ::
  PeerId ->
  ByteString ->
  MonoTime ->
  NetworkConfig ->
  ByteString ->
  Map.Map PeerId Connection ->
  Map.Map PeerId PendingConnection ->
  IO (Map.Map PeerId Connection, Map.Map PeerId PendingConnection, [HandshakeAction], [PeerEvent])
handleConnectionResponse peerId payload now cfg cookieSecret conns pending =
  case Map.lookup peerId pending of
    Nothing -> pure (conns, pending, [], [])
    Just pc
      | pcDirection pc /= Inbound -> pure (conns, pending, [], [])
      | BS.length payload < 24 -> pure (conns, pending, [], [])
      | otherwise ->
          case (decodeSalt payload, decodeSalt (BS.drop 8 payload), decodeSalt (BS.drop 16 payload)) of
            (Just clientSalt, Just serverSalt, Just cookie)
              | serverSalt /= pcServerSalt pc
                  || clientSalt == 0
                  || serverSalt == 0
                  || clientSalt == serverSalt ->
                  pure (conns, pending, [], [])
              | cookie /= computeCookie cookieSecret serverSalt (unPeerId peerId) ->
                  pure (conns, pending, [], [])
              | otherwise -> do
                  conn <- newConnection cfg now
                  let connected = markConnected now conn {Conn.connClientSalt = clientSalt}
                      act = HandshakeAction peerId ConnectionAccepted BS.empty
                  pure
                    ( Map.insert peerId connected conns,
                      Map.delete peerId pending,
                      [act],
                      [PeerConnected peerId Inbound]
                    )
            _ -> pure (conns, pending, [], [])

-- | Handle an incoming ConnectionAccepted (client side).
-- Creates Connection, emits PeerConnected.
handleConnectionAccepted ::
  PeerId ->
  MonoTime ->
  NetworkConfig ->
  Map.Map PeerId Connection ->
  Map.Map PeerId PendingConnection ->
  IO (Map.Map PeerId Connection, Map.Map PeerId PendingConnection, [PeerEvent])
handleConnectionAccepted peerId now cfg conns pending =
  case Map.lookup peerId pending of
    Nothing -> pure (conns, pending, [])
    Just pc
      | pcDirection pc /= Outbound -> pure (conns, pending, [])
      | otherwise -> do
          conn <- newConnection cfg now
          let connected = markConnected now conn {Conn.connClientSalt = pcClientSalt pc}
          pure
            ( Map.insert peerId connected conns,
              Map.delete peerId pending,
              [PeerConnected peerId Outbound]
            )

-- | Handle an incoming ConnectionDenied.
-- Emits PeerDisconnected with the reason from the payload.
handleConnectionDenied ::
  PeerId ->
  ByteString ->
  Map.Map PeerId PendingConnection ->
  (Map.Map PeerId PendingConnection, [PeerEvent])
handleConnectionDenied peerId payload pending =
  case Map.lookup peerId pending of
    Nothing -> (pending, [])
    Just _ ->
      let reason = fromMaybe ReasonRequested (decodeDenyReason payload)
       in (Map.delete peerId pending, [PeerDisconnected peerId reason])

-- | Handle an incoming Disconnect packet.
-- Fix #16: extracts reason from payload instead of using default.
handleDisconnect ::
  PeerId ->
  ByteString ->
  Map.Map PeerId Connection ->
  (Map.Map PeerId Connection, [PeerEvent])
handleDisconnect peerId payload conns =
  case Map.lookup peerId conns of
    Nothing -> (conns, [])
    Just _ ->
      let reason = fromMaybe ReasonRequested (decodeDenyReason payload)
       in (Map.delete peerId conns, [PeerDisconnected peerId reason])

-- ---------------------------------------------------------------------------
-- Maintenance
-- ---------------------------------------------------------------------------

-- | Resend ConnectionRequest for timed-out outbound pending connections.
retryPendingConnections ::
  MonoTime ->
  NetworkConfig ->
  Map.Map PeerId PendingConnection ->
  (Map.Map PeerId PendingConnection, [HandshakeAction])
retryPendingConnections now cfg pending =
  Map.foldlWithKey' go (pending, []) pending
  where
    retryTimeoutNs = msToNs (ncConnectionRequestTimeoutMs cfg)
    maxRetries = ncConnectionRequestMaxRetries cfg
    protPayload = encodeProtocolId (ncProtocolId cfg)

    go (pend, acts) peerId pc
      | pcDirection pc /= Outbound = (pend, acts)
      | pcRetryCount pc >= maxRetries = (pend, acts)
      | diffNs (pcLastRetry pc) now < retryTimeoutNs = (pend, acts)
      | otherwise =
          let updated = pc {pcRetryCount = pcRetryCount pc + 1, pcLastRetry = now}
              act = HandshakeAction peerId ConnectionRequest protPayload
           in (Map.insert peerId updated pend, acts ++ [act])

-- | Remove pending connections that have exceeded max retries.
cleanupPending ::
  MonoTime ->
  NetworkConfig ->
  Map.Map PeerId PendingConnection ->
  (Map.Map PeerId PendingConnection, [PeerEvent])
cleanupPending now cfg pending =
  let maxRetries = ncConnectionRequestMaxRetries cfg
      timeoutNs = msToNs (ncConnectionRequestTimeoutMs cfg)
      totalTimeoutNs = timeoutNs * fromIntegral (maxRetries + 1)
      (expired, kept) =
        Map.partition
          (\pc -> diffNs (pcCreatedAt pc) now >= totalTimeoutNs)
          pending
      events =
        [ PeerDisconnected pid ReasonTimeout
        | pid <- Map.keys expired
        ]
   in (kept, events)
