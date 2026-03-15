-- |
-- Module      : NovaNet.FFI.Random
-- Description : FFI bindings to nn_random (OS CSPRNG)
--
-- Generates cryptographically secure random bytes using the
-- best available OS primitive.  Setup only — not hot path.
module NovaNet.FFI.Random
  ( randomBytes,
    randomWord64,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Internal (create)
import Data.Word (Word64, Word8)
import Foreign.C.Types (CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr, castPtr)
import Foreign.Storable (peek)

foreign import ccall safe "nn_ffi_random_bytes"
  c_random_bytes :: Ptr Word8 -> CSize -> IO ()

-- | Generate the given number of cryptographically secure random bytes.
randomBytes :: Int -> IO ByteString
randomBytes n = create n $ \ptr -> c_random_bytes ptr (fromIntegral n)

-- | Generate a single random 'Word64'.
randomWord64 :: IO Word64
randomWord64 =
  alloca $ \ptr -> do
    c_random_bytes (castPtr ptr) 8
    peek ptr
