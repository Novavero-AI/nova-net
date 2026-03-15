-- |
-- Module      : NovaNet.Types
-- Description : Domain newtypes and core ADTs for type-safe networking
--
-- Zero-cost newtypes for channel IDs, sequence numbers, message IDs,
-- and monotonic time. Core ADTs for packet types, delivery modes,
-- connection states, and peer events.
module NovaNet.Types
  ( -- * Identifiers
    ChannelId,
    unChannelId,
    mkChannelId,
    channelIdToInt,
    SequenceNum (..),
    initialSeq,
    nextSeq,
    MessageId (..),
    initialMessageId,
    nextMessageId,
    PeerId (..),
    NonceCounter (..),
    initialNonce,
    nextNonce,

    -- * Time
    MonoTime (..),
    addNs,
    diffNs,
    Milliseconds (..),
    addMs,
    scaleMs,
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

    -- * Config policies
    FullBufferPolicy (..),
    CongestionMode (..),
    MigrationPolicy (..),

    -- * Encryption
    EncryptionKey,
    unEncryptionKey,
    mkEncryptionKey,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word16, Word32, Word64, Word8)
import Network.Socket (SockAddr)

-- ---------------------------------------------------------------------------
-- Identifiers
-- ---------------------------------------------------------------------------

-- | Channel identifier (0-7, 3 bits on wire).
-- Use 'mkChannelId' to construct; values outside 0-7 are rejected.
newtype ChannelId = ChannelId
  { -- | Unwrap the raw channel byte.
    unChannelId :: Word8
  }
  deriving (Eq, Ord, Show)

-- | Construct a 'ChannelId'. Returns 'Nothing' if the value exceeds 7.
mkChannelId :: Word8 -> Maybe ChannelId
mkChannelId w
  | w <= 7 = Just (ChannelId w)
  | otherwise = Nothing
{-# INLINE mkChannelId #-}

-- | Convert to 'Int' for indexing.
channelIdToInt :: ChannelId -> Int
channelIdToInt (ChannelId c) = fromIntegral c
{-# INLINE channelIdToInt #-}

-- | Packet sequence number with wraparound semantics.
-- No 'Ord' instance: use 'NovaNet.FFI.Seq.seqGt' for circular comparison.
-- No 'Num' instance: use 'nextSeq' to advance.
newtype SequenceNum = SequenceNum {unSequenceNum :: Word16}
  deriving (Eq, Show)

-- | The initial sequence number (0).
initialSeq :: SequenceNum
initialSeq = SequenceNum 0
{-# INLINE initialSeq #-}

-- | Advance to the next sequence number (wraps at 16-bit boundary).
nextSeq :: SequenceNum -> SequenceNum
nextSeq (SequenceNum s) = SequenceNum (s + 1)
{-# INLINE nextSeq #-}

-- | Fragment message identifier.
-- Use 'initialMessageId' and 'nextMessageId' to construct and advance.
newtype MessageId = MessageId {unMessageId :: Word32}
  deriving (Eq, Show)

-- | The initial message ID (0).
initialMessageId :: MessageId
initialMessageId = MessageId 0
{-# INLINE initialMessageId #-}

-- | Advance to the next message ID (wraps at 32-bit boundary).
nextMessageId :: MessageId -> MessageId
nextMessageId (MessageId m) = MessageId (m + 1)
{-# INLINE nextMessageId #-}

-- | Peer identifier (wraps a socket address).
newtype PeerId = PeerId {unPeerId :: SockAddr}
  deriving (Eq, Ord, Show)

-- | Monotonically increasing nonce counter for anti-replay.
-- Use 'initialNonce' and 'nextNonce' to construct and advance.
newtype NonceCounter = NonceCounter {unNonceCounter :: Word64}
  deriving (Eq, Ord, Show)

-- | The initial nonce counter (0).
initialNonce :: NonceCounter
initialNonce = NonceCounter 0
{-# INLINE initialNonce #-}

-- | Advance to the next nonce value.
nextNonce :: NonceCounter -> NonceCounter
nextNonce (NonceCounter n) = NonceCounter (n + 1)
{-# INLINE nextNonce #-}

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

-- | Monotonic time in nanoseconds. Use 'addNs' and 'diffNs' for
-- arithmetic instead of raw 'Num' operations.
newtype MonoTime = MonoTime {unMonoTime :: Word64}
  deriving (Eq, Ord, Show)

-- | Advance a timestamp by a duration in nanoseconds.
addNs :: MonoTime -> Word64 -> MonoTime
addNs (MonoTime t) delta = MonoTime (t + delta)
{-# INLINE addNs #-}

-- | Nanoseconds between two timestamps. Caller must ensure
-- @now >= start@; underflow wraps (Word64 semantics).
diffNs :: MonoTime -> MonoTime -> Word64
diffNs (MonoTime start) (MonoTime now) = now - start
{-# INLINE diffNs #-}

-- | Type-safe milliseconds to prevent unit mixing with seconds or
-- nanoseconds. All timeout and interval config fields use this type.
newtype Milliseconds = Milliseconds {unMilliseconds :: Double}
  deriving (Eq, Ord, Show)

-- | Add two durations.
addMs :: Milliseconds -> Milliseconds -> Milliseconds
addMs (Milliseconds a) (Milliseconds b) = Milliseconds (a + b)
{-# INLINE addMs #-}

-- | Scale a duration by a factor.
scaleMs :: Milliseconds -> Double -> Milliseconds
scaleMs (Milliseconds ms) factor = Milliseconds (ms * factor)
{-# INLINE scaleMs #-}

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
isReliable Unreliable = False
isReliable UnreliableSequenced = False
{-# INLINE isReliable #-}

-- | Does this mode drop out-of-order messages?
isSequenced :: DeliveryMode -> Bool
isSequenced UnreliableSequenced = True
isSequenced ReliableSequenced = True
isSequenced Unreliable = False
isSequenced ReliableUnordered = False
isSequenced ReliableOrdered = False
{-# INLINE isSequenced #-}

-- | Does this mode buffer and reorder for strict FIFO delivery?
isOrdered :: DeliveryMode -> Bool
isOrdered ReliableOrdered = True
isOrdered Unreliable = False
isOrdered UnreliableSequenced = False
isOrdered ReliableUnordered = False
isOrdered ReliableSequenced = False
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
-- Config policies
-- ---------------------------------------------------------------------------

-- | Policy when a channel's message buffer is full.
data FullBufferPolicy
  = DropOnFull
  | BlockOnFull
  deriving (Eq, Ord, Show)

-- | Congestion control mode.
data CongestionMode
  = BinaryAIMD
  | CwndTcpLike
  deriving (Eq, Ord, Show)

-- | Connection migration policy.
data MigrationPolicy
  = MigrationEnabled
  | MigrationDisabled
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Encryption
-- ---------------------------------------------------------------------------

-- | 256-bit encryption key for ChaCha20-Poly1305.
-- Use 'mkEncryptionKey' to construct; only accepts exactly 32 bytes.
newtype EncryptionKey = EncryptionKey
  { -- | Unwrap the raw 32-byte key.
    unEncryptionKey :: ByteString
  }
  deriving (Eq)

-- | Construct an 'EncryptionKey'. Returns 'Nothing' if the ByteString
-- is not exactly 32 bytes.
mkEncryptionKey :: ByteString -> Maybe EncryptionKey
mkEncryptionKey bs
  | BS.length bs == 32 = Just (EncryptionKey bs)
  | otherwise = Nothing

instance Show EncryptionKey where
  show _ = "EncryptionKey <redacted>"
