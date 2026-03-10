-- |
-- Module      : NovaNet.Types
-- Description : Domain newtypes for type-safe networking
--
-- Zero-cost newtypes for channel IDs, sequence numbers, message IDs,
-- and monotonic time. These prevent mixing up bare Word values across
-- the API boundary.
module NovaNet.Types
  ( ChannelId (..),
    SequenceNum (..),
    MessageId (..),
    MonoTime (..),
    NonceCounter (..),
  )
where

import Data.Word (Word16, Word32, Word64, Word8)

-- | Channel identifier (0-7, 3 bits on wire).
newtype ChannelId = ChannelId {unChannelId :: Word8}
  deriving (Eq, Ord, Show)

-- | Packet sequence number with wraparound semantics.
newtype SequenceNum = SequenceNum {unSequenceNum :: Word16}
  deriving (Eq, Ord, Show)

instance Num SequenceNum where
  SequenceNum a + SequenceNum b = SequenceNum (a + b)
  SequenceNum a - SequenceNum b = SequenceNum (a - b)
  SequenceNum a * SequenceNum b = SequenceNum (a * b)
  abs = id
  signum (SequenceNum s) = SequenceNum (signum s)
  fromInteger = SequenceNum . fromInteger

-- | Fragment message identifier.
newtype MessageId = MessageId {unMessageId :: Word32}
  deriving (Eq, Ord, Show)

-- | Monotonic time in nanoseconds.
newtype MonoTime = MonoTime {unMonoTime :: Word64}
  deriving (Eq, Ord, Show)

instance Num MonoTime where
  MonoTime a + MonoTime b = MonoTime (a + b)
  MonoTime a - MonoTime b = MonoTime (a - b)
  MonoTime a * MonoTime b = MonoTime (a * b)
  abs = id
  signum (MonoTime t) = MonoTime (signum t)
  fromInteger = MonoTime . fromInteger

-- | Monotonically increasing nonce counter for anti-replay.
newtype NonceCounter = NonceCounter {unNonceCounter :: Word64}
  deriving (Eq, Ord, Show)
