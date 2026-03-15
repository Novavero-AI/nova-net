-- |
-- Module      : NovaNet.Peer.Protocol
-- Description : Pure encoding/decoding for peer wire protocol
--
-- Payload header byte, LE scalar encoding for salts, protocol IDs,
-- channel sequences, and disconnect reasons.  Zero dependencies on
-- other new Phase 4 modules.
module NovaNet.Peer.Protocol
  ( -- * Payload header byte
    encodePayloadHeader,
    decodePayloadHeader,

    -- * Salt (8 bytes LE)
    encodeSalt,
    decodeSalt,

    -- * Protocol ID (4 bytes LE)
    encodeProtocolId,
    decodeProtocolId,

    -- * Channel sequence (2 bytes LE)
    encodeChannelSeq,
    decodeChannelSeq,

    -- * Deny reason (1 byte)
    encodeDenyReason,
    decodeDenyReason,

    -- * Post-handshake check
    isPostHandshake,
  )
where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Word (Word16, Word32, Word64, Word8)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Payload header byte
-- ---------------------------------------------------------------------------

-- | Encode a payload header byte.
-- Layout: [is_fragment:1][reserved:4][channel:3]
encodePayloadHeader :: ChannelId -> Bool -> Word8
encodePayloadHeader cid isFragment =
  let chanBits = unChannelId cid .&. 0x07
      fragBit = if isFragment then 0x80 else 0x00
   in fragBit .|. chanBits
{-# INLINE encodePayloadHeader #-}

-- | Decode a payload header byte.
-- Returns (ChannelId, isFragment) or Nothing for invalid channel.
decodePayloadHeader :: Word8 -> Maybe (ChannelId, Bool)
decodePayloadHeader w =
  let chanBits = w .&. 0x07
      isFragment = (w .&. 0x80) /= 0
   in case mkChannelId chanBits of
        Just cid -> Just (cid, isFragment)
        Nothing -> Nothing
{-# INLINE decodePayloadHeader #-}

-- ---------------------------------------------------------------------------
-- Salt (8 bytes LE)
-- ---------------------------------------------------------------------------

-- | Encode a 64-bit salt as 8 bytes little-endian.
encodeSalt :: Word64 -> ByteString
encodeSalt val =
  BS.pack
    [ fromIntegral (val .&. 0xFF),
      fromIntegral ((val `shiftR` 8) .&. 0xFF),
      fromIntegral ((val `shiftR` 16) .&. 0xFF),
      fromIntegral ((val `shiftR` 24) .&. 0xFF),
      fromIntegral ((val `shiftR` 32) .&. 0xFF),
      fromIntegral ((val `shiftR` 40) .&. 0xFF),
      fromIntegral ((val `shiftR` 48) .&. 0xFF),
      fromIntegral ((val `shiftR` 56) .&. 0xFF)
    ]
{-# INLINE encodeSalt #-}

-- | Decode 8 bytes little-endian to a 64-bit salt.
decodeSalt :: ByteString -> Maybe Word64
decodeSalt bs
  | BS.length bs < 8 = Nothing
  | otherwise =
      let b0 = fromIntegral (BS.index bs 0) :: Word64
          b1 = fromIntegral (BS.index bs 1) :: Word64
          b2 = fromIntegral (BS.index bs 2) :: Word64
          b3 = fromIntegral (BS.index bs 3) :: Word64
          b4 = fromIntegral (BS.index bs 4) :: Word64
          b5 = fromIntegral (BS.index bs 5) :: Word64
          b6 = fromIntegral (BS.index bs 6) :: Word64
          b7 = fromIntegral (BS.index bs 7) :: Word64
       in Just $
            b0
              .|. (b1 `shiftL` 8)
              .|. (b2 `shiftL` 16)
              .|. (b3 `shiftL` 24)
              .|. (b4 `shiftL` 32)
              .|. (b5 `shiftL` 40)
              .|. (b6 `shiftL` 48)
              .|. (b7 `shiftL` 56)
{-# INLINE decodeSalt #-}

-- ---------------------------------------------------------------------------
-- Protocol ID (4 bytes LE)
-- ---------------------------------------------------------------------------

-- | Encode a 32-bit protocol ID as 4 bytes little-endian.
encodeProtocolId :: Word32 -> ByteString
encodeProtocolId val =
  BS.pack
    [ fromIntegral (val .&. 0xFF),
      fromIntegral ((val `shiftR` 8) .&. 0xFF),
      fromIntegral ((val `shiftR` 16) .&. 0xFF),
      fromIntegral ((val `shiftR` 24) .&. 0xFF)
    ]
{-# INLINE encodeProtocolId #-}

-- | Decode 4 bytes little-endian to a 32-bit protocol ID.
decodeProtocolId :: ByteString -> Maybe Word32
decodeProtocolId bs
  | BS.length bs < 4 = Nothing
  | otherwise =
      let b0 = fromIntegral (BS.index bs 0) :: Word32
          b1 = fromIntegral (BS.index bs 1) :: Word32
          b2 = fromIntegral (BS.index bs 2) :: Word32
          b3 = fromIntegral (BS.index bs 3) :: Word32
       in Just $ b0 .|. (b1 `shiftL` 8) .|. (b2 `shiftL` 16) .|. (b3 `shiftL` 24)
{-# INLINE decodeProtocolId #-}

-- ---------------------------------------------------------------------------
-- Channel sequence (2 bytes LE)
-- ---------------------------------------------------------------------------

-- | Encode a channel sequence number as 2 bytes little-endian.
encodeChannelSeq :: SequenceNum -> ByteString
encodeChannelSeq (SequenceNum val) =
  BS.pack
    [ fromIntegral (val .&. 0xFF),
      fromIntegral ((val `shiftR` 8) .&. 0xFF)
    ]
{-# INLINE encodeChannelSeq #-}

-- | Decode 2 bytes little-endian to a channel sequence number.
decodeChannelSeq :: ByteString -> Maybe SequenceNum
decodeChannelSeq bs
  | BS.length bs < 2 = Nothing
  | otherwise =
      let lo = fromIntegral (BS.index bs 0) :: Word16
          hi = fromIntegral (BS.index bs 1) :: Word16
       in Just $ SequenceNum (lo .|. (hi `shiftL` 8))
{-# INLINE decodeChannelSeq #-}

-- ---------------------------------------------------------------------------
-- Deny reason (1 byte)
-- ---------------------------------------------------------------------------

-- | Encode a disconnect reason as 1 byte.
encodeDenyReason :: DisconnectReason -> ByteString
encodeDenyReason = BS.singleton . disconnectReasonCode
{-# INLINE encodeDenyReason #-}

-- | Decode 1 byte to a disconnect reason.
decodeDenyReason :: ByteString -> Maybe DisconnectReason
decodeDenyReason bs = case BS.uncons bs of
  Just (w, _) -> Just (parseDisconnectReason w)
  Nothing -> Nothing
{-# INLINE decodeDenyReason #-}

-- ---------------------------------------------------------------------------
-- Post-handshake check
-- ---------------------------------------------------------------------------

-- | Is this a post-handshake packet type?
-- Post-handshake packets carry encrypted data and use the connection
-- nonce/sequence machinery.
isPostHandshake :: PacketType -> Bool
isPostHandshake Payload = True
isPostHandshake Keepalive = True
isPostHandshake Disconnect = True
isPostHandshake _ = False
{-# INLINE isPostHandshake #-}
