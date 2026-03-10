-- |
-- Module      : NovaNet.FFI.Packet
-- Description : FFI bindings to nn_packet (9-byte wire header)
module NovaNet.FFI.Packet
  ( -- * Constants
    packetHeaderSize,

    -- * Packet types
    PacketType (..),
    packetTypeToWord8,
    packetTypeFromWord8,

    -- * Write / Read
    packetWrite,
    packetRead,
  )
where

import Data.Word (Word16, Word32, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

-- | Packet header size in bytes.
packetHeaderSize :: Int
packetHeaderSize = 9

-- | Packet type tag (4 bits on wire).
data PacketType
  = ConnectionRequest
  | ConnectionAccepted
  | ConnectionDenied
  | Payload
  | Disconnect
  | Keepalive
  | ConnectionChallenge
  | ConnectionResponse
  deriving (Eq, Show, Enum, Bounded)

packetTypeToWord8 :: PacketType -> Word8
packetTypeToWord8 = fromIntegral . fromEnum
{-# INLINE packetTypeToWord8 #-}

packetTypeFromWord8 :: Word8 -> Maybe PacketType
packetTypeFromWord8 w
  | w <= fromIntegral (fromEnum (maxBound :: PacketType)) = Just (toEnum (fromIntegral w))
  | otherwise = Nothing
{-# INLINE packetTypeFromWord8 #-}

foreign import ccall unsafe "nn_ffi_packet_write"
  c_packet_write :: Word8 -> Word16 -> Word16 -> Word32 -> Ptr Word8 -> IO CInt

foreign import ccall unsafe "nn_ffi_packet_read"
  c_packet_read :: Ptr Word8 -> CSize -> Ptr Word8 -> Ptr Word16 -> Ptr Word16 -> Ptr Word32 -> IO CInt

-- | Write a packet header to a buffer. Returns bytes written (always 9).
packetWrite :: Word8 -> Word16 -> Word16 -> Word32 -> Ptr Word8 -> IO Int
packetWrite pt seqNum ackNum abf buf =
  fromIntegral <$> c_packet_write pt seqNum ackNum abf buf
{-# INLINE packetWrite #-}

-- | Read a packet header from a buffer.
packetRead ::
  Ptr Word8 ->
  Int ->
  IO (Maybe (Word8, Word16, Word16, Word32))
packetRead buf len =
  alloca $ \ptPtr ->
    alloca $ \snPtr ->
      alloca $ \akPtr ->
        alloca $ \abfPtr -> do
          rc <- c_packet_read buf (fromIntegral len) ptPtr snPtr akPtr abfPtr
          if rc /= 0
            then return Nothing
            else do
              pt <- peek ptPtr
              sn <- peek snPtr
              ak <- peek akPtr
              abf <- peek abfPtr
              return (Just (pt, sn, ak, abf))
{-# INLINE packetRead #-}
