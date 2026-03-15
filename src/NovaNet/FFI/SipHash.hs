-- |
-- Module      : NovaNet.FFI.SipHash
-- Description : FFI bindings to nn_siphash (SipHash-2-4)
--
-- Keyed PRF for HMAC-bound challenge cookies during handshake.
-- 128-bit key, 64-bit output.
module NovaNet.FFI.SipHash
  ( siphash,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word64, Word8)
import Foreign.C.Types (CSize (..))
import Foreign.Ptr (Ptr, castPtr)
import System.IO.Unsafe (unsafeDupablePerformIO)

foreign import ccall unsafe "nn_ffi_siphash"
  c_siphash :: Ptr Word8 -> Ptr Word8 -> CSize -> Word64

-- | Compute SipHash-2-4. Key must be exactly 16 bytes.
-- Returns 0 for invalid key lengths.
siphash :: ByteString -> ByteString -> Word64
siphash key msg
  | BS.length key /= 16 = 0
  | otherwise =
      unsafeDupablePerformIO $
        BSU.unsafeUseAsCStringLen key $ \(keyPtr, _) ->
          BSU.unsafeUseAsCStringLen msg $ \(msgPtr, msgLen) ->
            pure $
              c_siphash
                (castPtr keyPtr)
                (castPtr msgPtr)
                (fromIntegral msgLen)
{-# INLINE siphash #-}
