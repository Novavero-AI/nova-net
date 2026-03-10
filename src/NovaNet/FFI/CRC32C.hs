-- |
-- Module      : NovaNet.FFI.CRC32C
-- Description : FFI bindings to nn_crc32c (hardware-accelerated CRC32C)
module NovaNet.FFI.CRC32C
  ( crc32cSize,
    crc32c,
    crc32cAppend,
    crc32cValidate,
  )
where

import Data.Word (Word32, Word8)
import Foreign.C.Types (CSize (..))
import Foreign.Ptr (Ptr)

-- | CRC32C checksum size in bytes.
crc32cSize :: Int
crc32cSize = 4

foreign import ccall unsafe "nn_ffi_crc32c"
  c_crc32c :: Ptr Word8 -> CSize -> IO Word32

foreign import ccall unsafe "nn_ffi_crc32c_append"
  c_crc32c_append :: Ptr Word8 -> CSize -> IO CSize

foreign import ccall unsafe "nn_ffi_crc32c_validate"
  c_crc32c_validate :: Ptr Word8 -> CSize -> IO CSize

-- | Compute CRC32C checksum.
crc32c :: Ptr Word8 -> Int -> IO Word32
crc32c buf len = c_crc32c buf (fromIntegral len)
{-# INLINE crc32c #-}

-- | Append CRC32C to buffer. Returns new total length.
crc32cAppend :: Ptr Word8 -> Int -> IO Int
crc32cAppend buf dataLen = fromIntegral <$> c_crc32c_append buf (fromIntegral dataLen)
{-# INLINE crc32cAppend #-}

-- | Validate CRC32C. Returns payload length, or 0 on failure.
crc32cValidate :: Ptr Word8 -> Int -> IO Int
crc32cValidate buf totalLen = fromIntegral <$> c_crc32c_validate buf (fromIntegral totalLen)
{-# INLINE crc32cValidate #-}
