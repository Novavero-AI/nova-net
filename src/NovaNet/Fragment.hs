-- |
-- Module      : NovaNet.Fragment
-- Description : Message fragmentation and reassembly
--
-- Pure Haskell module.  Splits large messages into wire-ready
-- fragments and reassembles received fragments into complete messages.
-- Fragment headers are 6 bytes (little-endian message ID, index,
-- count).  Reassembly uses bounded memory with LRU eviction and
-- configurable timeouts.
module NovaNet.Fragment
  ( -- * Assembler
    FragmentAssembler,
    newFragmentAssembler,

    -- * Receive (reassembly)
    onFragmentReceived,
    assemblerUpdate,

    -- * Send (splitting)
    splitMessage,
    FragmentError (..),

    -- * Queries
    assemblerPendingCount,
    assemblerStatsCompleted,
    assemblerStatsTimedOut,
    assemblerCurrentSize,
  )
where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.IntMap.Strict as IM
import Data.Word (Word32, Word64, Word8)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Fragment header size in bytes (4 LE message ID + 1 index + 1 count).
-- Matches NN_FRAGMENT_HEADER_SIZE in nn_fragment.h.
fragHeaderSize :: Int
fragHeaderSize = 6

-- | Maximum fragments per message (Word8 wire constraint).
fragMaxCount :: Int
fragMaxCount = 255

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | Why message splitting failed.
data FragmentError = TooManyFragments
  deriving (Eq, Show)

-- | Per-message reassembly state.
data FragmentBuffer = FragmentBuffer
  { fbFragments :: !(IM.IntMap ByteString),
    fbFragmentCount :: !Word8,
    fbCreatedAt :: !MonoTime,
    fbTotalSize :: !Int
  }

-- | Top-level fragment reassembly state.  Manages all in-progress
-- reassemblies with bounded memory and timeout cleanup.
data FragmentAssembler = FragmentAssembler
  { faBuffers :: !(IM.IntMap FragmentBuffer),
    faTimeoutNs :: !Word64,
    faMaxBufferSize :: !Int,
    faCurrentBufferSize :: !Int,
    faStatsCompleted :: !Word64,
    faStatsTimedOut :: !Word64
  }

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a new fragment assembler with the given timeout and
-- maximum buffer size in bytes.
newFragmentAssembler :: Milliseconds -> Int -> FragmentAssembler
newFragmentAssembler timeout maxSize =
  FragmentAssembler
    { faBuffers = IM.empty,
      faTimeoutNs = msToNs timeout,
      faMaxBufferSize = maxSize,
      faCurrentBufferSize = 0,
      faStatsCompleted = 0,
      faStatsTimedOut = 0
    }

-- ---------------------------------------------------------------------------
-- Splitting (sender)
-- ---------------------------------------------------------------------------

-- | Split a message into fragments with prepended headers.
-- Each returned 'ByteString' is: fragment header (6 bytes) + data slice.
-- The caller provides the maximum data bytes per fragment (excluding
-- the 6-byte header).  Returns 'Left TooManyFragments' when the
-- message would exceed 255 fragments or the max payload is non-positive.
splitMessage ::
  MessageId ->
  ByteString ->
  Int ->
  Either FragmentError [ByteString]
splitMessage _ _ maxPayload
  | maxPayload <= 0 = Left TooManyFragments
splitMessage msgId payload maxPayload
  | fragCount > fragMaxCount = Left TooManyFragments
  | msgLen == 0 = Right []
  | otherwise = Right (map buildOne [0 .. fragCount - 1])
  where
    msgLen = BS.length payload
    fragCount = (msgLen + maxPayload - 1) `div` maxPayload
    cnt = fromIntegral fragCount :: Word8
    mid = unMessageId msgId

    buildOne i =
      let offset = i * maxPayload
          slice = BS.take maxPayload (BS.drop offset payload)
          hdr = encodeHeader mid (fromIntegral i) cnt
       in hdr <> slice

-- ---------------------------------------------------------------------------
-- Reassembly (receiver)
-- ---------------------------------------------------------------------------

-- | Process an incoming fragment.  The payload must begin with a
-- 6-byte fragment header.  Returns the completed reassembled message
-- (all data portions concatenated in index order) when the final
-- fragment arrives.  Invalid or duplicate fragments are silently
-- ignored.
onFragmentReceived ::
  ByteString ->
  MonoTime ->
  FragmentAssembler ->
  (Maybe ByteString, FragmentAssembler)
onFragmentReceived raw now asm =
  case decodeHeader raw of
    Nothing -> (Nothing, asm)
    Just (msgId, idx, cnt)
      | cnt == 0 -> (Nothing, asm)
      | idx >= cnt -> (Nothing, asm)
      | otherwise ->
          let fragData = BS.drop fragHeaderSize raw
              key = fromIntegral msgId
              idxKey = fromIntegral idx
              dataLen = BS.length fragData
           in insertFragment key idxKey cnt fragData dataLen now asm

insertFragment ::
  Int ->
  Int ->
  Word8 ->
  ByteString ->
  Int ->
  MonoTime ->
  FragmentAssembler ->
  (Maybe ByteString, FragmentAssembler)
insertFragment key idxKey cnt fragData dataLen now asm =
  case IM.lookup key (faBuffers asm) of
    Nothing ->
      -- New message: create buffer
      let buf =
            FragmentBuffer
              { fbFragments = IM.singleton idxKey fragData,
                fbFragmentCount = cnt,
                fbCreatedAt = now,
                fbTotalSize = dataLen
              }
          asm2 =
            evictIfNeeded $
              asm
                { faBuffers = IM.insert key buf (faBuffers asm),
                  faCurrentBufferSize = faCurrentBufferSize asm + dataLen
                }
       in tryComplete key asm2
    Just buf
      -- Count mismatch with existing buffer
      | fbFragmentCount buf /= cnt -> (Nothing, asm)
      -- Duplicate fragment index
      | IM.member idxKey (fbFragments buf) -> (Nothing, asm)
      | otherwise ->
          let updated =
                buf
                  { fbFragments = IM.insert idxKey fragData (fbFragments buf),
                    fbTotalSize = fbTotalSize buf + dataLen
                  }
              asm2 =
                evictIfNeeded $
                  asm
                    { faBuffers = IM.insert key updated (faBuffers asm),
                      faCurrentBufferSize = faCurrentBufferSize asm + dataLen
                    }
           in tryComplete key asm2

tryComplete :: Int -> FragmentAssembler -> (Maybe ByteString, FragmentAssembler)
tryComplete key asm =
  case IM.lookup key (faBuffers asm) of
    Nothing -> (Nothing, asm)
    Just buf
      | IM.size (fbFragments buf) == fromIntegral (fbFragmentCount buf) ->
          -- All fragments arrived — concatenate in index order
          let assembled = mconcat [v | (_, v) <- IM.toAscList (fbFragments buf)]
           in ( Just assembled,
                asm
                  { faBuffers = IM.delete key (faBuffers asm),
                    faCurrentBufferSize = faCurrentBufferSize asm - fbTotalSize buf,
                    faStatsCompleted = faStatsCompleted asm + 1
                  }
              )
      | otherwise -> (Nothing, asm)

-- ---------------------------------------------------------------------------
-- Timeout cleanup
-- ---------------------------------------------------------------------------

-- | Remove incomplete reassemblies that have exceeded the timeout.
-- Call once per tick.
assemblerUpdate :: MonoTime -> FragmentAssembler -> FragmentAssembler
assemblerUpdate now asm =
  let timeoutNs = faTimeoutNs asm
      isExpired buf = diffNs (fbCreatedAt buf) now >= timeoutNs
      (expired, kept) = IM.partition isExpired (faBuffers asm)
      expiredSize = IM.foldl' (\acc buf -> acc + fbTotalSize buf) 0 expired
      expiredCount = fromIntegral (IM.size expired)
   in asm
        { faBuffers = kept,
          faCurrentBufferSize = faCurrentBufferSize asm - expiredSize,
          faStatsTimedOut = faStatsTimedOut asm + expiredCount
        }

-- ---------------------------------------------------------------------------
-- Memory management
-- ---------------------------------------------------------------------------

-- | Evict oldest incomplete buffers until memory usage is within bounds.
evictIfNeeded :: FragmentAssembler -> FragmentAssembler
evictIfNeeded asm
  | faCurrentBufferSize asm <= faMaxBufferSize asm = asm
  | IM.null (faBuffers asm) = asm
  | otherwise =
      case findOldestBuffer (faBuffers asm) of
        Nothing -> asm
        Just (oldKey, oldBuf) ->
          evictIfNeeded
            asm
              { faBuffers = IM.delete oldKey (faBuffers asm),
                faCurrentBufferSize = faCurrentBufferSize asm - fbTotalSize oldBuf,
                faStatsTimedOut = faStatsTimedOut asm + 1
              }

findOldestBuffer :: IM.IntMap FragmentBuffer -> Maybe (Int, FragmentBuffer)
findOldestBuffer = IM.foldlWithKey' go Nothing
  where
    go Nothing key buf = Just (key, buf)
    go (Just (bestKey, bestBuf)) key buf
      | fbCreatedAt buf < fbCreatedAt bestBuf = Just (key, buf)
      | otherwise = Just (bestKey, bestBuf)

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Number of messages currently being reassembled.
assemblerPendingCount :: FragmentAssembler -> Int
assemblerPendingCount = IM.size . faBuffers
{-# INLINE assemblerPendingCount #-}

-- | Total successfully reassembled messages.
assemblerStatsCompleted :: FragmentAssembler -> Word64
assemblerStatsCompleted = faStatsCompleted
{-# INLINE assemblerStatsCompleted #-}

-- | Total incomplete messages that timed out or were evicted.
assemblerStatsTimedOut :: FragmentAssembler -> Word64
assemblerStatsTimedOut = faStatsTimedOut
{-# INLINE assemblerStatsTimedOut #-}

-- | Current reassembly buffer usage in bytes.
assemblerCurrentSize :: FragmentAssembler -> Int
assemblerCurrentSize = faCurrentBufferSize
{-# INLINE assemblerCurrentSize #-}

-- ---------------------------------------------------------------------------
-- Header encoding / decoding (little-endian wire format)
-- ---------------------------------------------------------------------------

encodeHeader :: Word32 -> Word8 -> Word8 -> ByteString
encodeHeader msgId idx cnt =
  BS.pack
    [ fromIntegral (msgId .&. 0xFF),
      fromIntegral ((msgId `shiftR` 8) .&. 0xFF),
      fromIntegral ((msgId `shiftR` 16) .&. 0xFF),
      fromIntegral ((msgId `shiftR` 24) .&. 0xFF),
      idx,
      cnt
    ]
{-# INLINE encodeHeader #-}

decodeHeader :: ByteString -> Maybe (Word32, Word8, Word8)
decodeHeader bs
  | BS.length bs < fragHeaderSize = Nothing
  | otherwise =
      let b0 = fromIntegral (BS.index bs 0) :: Word32
          b1 = fromIntegral (BS.index bs 1) :: Word32
          b2 = fromIntegral (BS.index bs 2) :: Word32
          b3 = fromIntegral (BS.index bs 3) :: Word32
          msgId = b0 .|. (b1 `shiftL` 8) .|. (b2 `shiftL` 16) .|. (b3 `shiftL` 24)
          idx = BS.index bs 4
          cnt = BS.index bs 5
       in Just (msgId, idx, cnt)
{-# INLINE decodeHeader #-}
