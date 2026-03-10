{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- |
-- Module      : NovaNet.Types
-- Description : Domain newtypes and core ADTs for type-safe networking
--
-- Zero-cost newtypes for channel IDs, sequence numbers, message IDs,
-- and monotonic time. Core ADTs for packet types, delivery modes,
-- connection states, and peer events.
module NovaNet.Types
  ( -- * Identifiers
    ChannelId (..),
    channelIdToInt,
    SequenceNum (..),
    MessageId (..),
    nextMessageId,
    PeerId (..),
    NonceCounter (..),
    nextNonce,

    -- * Time
    MonoTime (..),
    Milliseconds (..),
    msToNs,
    nsToMs,

    -- * Packet
    PacketType (..),
    packetTypeToWord8,
    packetTypeFromWord8,

    -- * Delivery
    DeliveryMode (..),
    isReliable,
    isSequenced,
    isOrdered,

    -- * Connection
    ConnectionState (..),
    ConnectionDirection (..),
    DisconnectReason (..),
    disconnectReasonCode,
    parseDisconnectReason,

    -- * Events
    PeerEvent (..),

    -- * Encryption
    EncryptionKey (..),
  )
where

import Data.ByteString (ByteString)
import Data.Word (Word16, Word32, Word64, Word8)
import Network.Socket (SockAddr)

-- ---------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------

-- | Channel identifier (0-7, 3 bits on wire).
newtype ChannelId = ChannelId {unChannelId :: Word8}
  deriving (Eq, Ord, Show)

-- | Convert to 'Int' for 'IntMap' indexing.
channelIdToInt :: ChannelId -> Int
channelIdToInt (ChannelId c) = fromIntegral c
{-# INLINE channelIdToInt #-}

-- | Packet sequence number with wraparound semantics.
-- 'Num' instance wraps at 16-bit boundaries, matching the wire format.
newtype SequenceNum = SequenceNum {unSequenceNum :: Word16}
  deriving (Eq, Ord, Show, Num)

-- | Fragment message identifier. Not a number — use 'nextMessageId'
-- to advance.
newtype MessageId = MessageId {unMessageId :: Word32}
  deriving (Eq, Ord, Show)

-- | Advance to the next message ID (wraps at 32-bit boundary).
nextMessageId :: MessageId -> MessageId
nextMessageId (MessageId m) = MessageId (m + 1)
{-# INLINE nextMessageId #-}

-- | Peer identifier (wraps a socket address).
newtype PeerId = PeerId {unPeerId :: SockAddr}
  deriving (Eq, Ord, Show)

-- | Monotonically increasing nonce counter for anti-replay.
-- Not a number — use 'nextNonce' to advance.
newtype NonceCounter = NonceCounter {unNonceCounter :: Word64}
  deriving (Eq, Ord, Show)

-- | Advance to the next nonce value.
nextNonce :: NonceCounter -> NonceCounter
nextNonce (NonceCounter n) = NonceCounter (n + 1)
{-# INLINE nextNonce #-}

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

-- | Monotonic time in nanoseconds. 'Num' instance enables @t + delta@.
newtype MonoTime = MonoTime {unMonoTime :: Word64}
  deriving (Eq, Ord, Show, Num)

-- | Type-safe milliseconds to prevent unit mixing with seconds or
-- nanoseconds. All timeout and interval config fields use this type.
newtype Milliseconds = Milliseconds {unMilliseconds :: Double}
  deriving (Eq, Ord, Show, Num, Fractional)

-- | Convert milliseconds to nanoseconds (for 'MonoTime' arithmetic).
msToNs :: Milliseconds -> Word64
msToNs (Milliseconds ms) = round (ms * 1e6)
{-# INLINE msToNs #-}

-- | Convert nanoseconds to milliseconds.
nsToMs :: Word64 -> Milliseconds
nsToMs ns = Milliseconds (fromIntegral ns / 1e6)
{-# INLINE nsToMs #-}

-- ---------------------------------------------------------------------------
-- Packet types
-- ---------------------------------------------------------------------------

-- | Packet type tag (4 bits on wire, 0-7).
data PacketType
  = ConnectionRequest
  | ConnectionAccepted
  | ConnectionDenied
  | Payload
  | Disconnect
  | Keepalive
  | ConnectionChallenge
  | ConnectionResponse
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Encode to wire value.
packetTypeToWord8 :: PacketType -> Word8
packetTypeToWord8 = fromIntegral . fromEnum
{-# INLINE packetTypeToWord8 #-}

-- | Decode from wire value. Returns 'Nothing' for invalid values.
packetTypeFromWord8 :: Word8 -> Maybe PacketType
packetTypeFromWord8 w
  | w <= fromIntegral (fromEnum (maxBound :: PacketType)) = Just (toEnum (fromIntegral w))
  | otherwise = Nothing
{-# INLINE packetTypeFromWord8 #-}

-- ---------------------------------------------------------------------------
-- Delivery modes
-- ---------------------------------------------------------------------------

-- | Channel delivery mode. Determines reliability and ordering guarantees.
data DeliveryMode
  = Unreliable
  | UnreliableSequenced
  | ReliableUnordered
  | ReliableOrdered
  | ReliableSequenced
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Does this mode guarantee delivery?
isReliable :: DeliveryMode -> Bool
isReliable ReliableUnordered = True
isReliable ReliableOrdered = True
isReliable ReliableSequenced = True
isReliable _ = False
{-# INLINE isReliable #-}

-- | Does this mode drop out-of-order messages?
isSequenced :: DeliveryMode -> Bool
isSequenced UnreliableSequenced = True
isSequenced ReliableSequenced = True
isSequenced _ = False
{-# INLINE isSequenced #-}

-- | Does this mode buffer and reorder for strict FIFO delivery?
isOrdered :: DeliveryMode -> Bool
isOrdered ReliableOrdered = True
isOrdered _ = False
{-# INLINE isOrdered #-}

-- ---------------------------------------------------------------------------
-- Connection state machine
-- ---------------------------------------------------------------------------

-- | Connection lifecycle state.
data ConnectionState
  = Disconnected
  | Connecting
  | Connected
  | Disconnecting
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Which side initiated the connection.
data ConnectionDirection
  = Inbound
  | Outbound
  deriving (Eq, Ord, Show)

-- | Reason for disconnection (wire codes 0-4, extensible).
data DisconnectReason
  = ReasonTimeout
  | ReasonRequested
  | ReasonKicked
  | ReasonServerFull
  | ReasonProtocolMismatch
  | ReasonUnknown !Word8
  deriving (Eq, Show)

-- | Encode to wire byte.
disconnectReasonCode :: DisconnectReason -> Word8
disconnectReasonCode ReasonTimeout = 0
disconnectReasonCode ReasonRequested = 1
disconnectReasonCode ReasonKicked = 2
disconnectReasonCode ReasonServerFull = 3
disconnectReasonCode ReasonProtocolMismatch = 4
disconnectReasonCode (ReasonUnknown w) = w

-- | Decode from wire byte.
parseDisconnectReason :: Word8 -> DisconnectReason
parseDisconnectReason 0 = ReasonTimeout
parseDisconnectReason 1 = ReasonRequested
parseDisconnectReason 2 = ReasonKicked
parseDisconnectReason 3 = ReasonServerFull
parseDisconnectReason 4 = ReasonProtocolMismatch
parseDisconnectReason w = ReasonUnknown w

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- | Events emitted from peer processing, consumed by the application.
data PeerEvent
  = PeerConnected !PeerId !ConnectionDirection
  | PeerDisconnected !PeerId !DisconnectReason
  | PeerMessage !PeerId !ChannelId !ByteString
  | PeerMigrated !PeerId !PeerId
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Encryption
-- ---------------------------------------------------------------------------

-- | 256-bit encryption key for ChaCha20-Poly1305.
newtype EncryptionKey = EncryptionKey {unEncryptionKey :: ByteString}
  deriving (Eq)

instance Show EncryptionKey where
  show _ = "EncryptionKey <redacted>"
