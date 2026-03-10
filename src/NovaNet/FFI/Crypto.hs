-- |
-- Module      : NovaNet.FFI.Crypto
-- Description : FFI bindings to nn_crypto (ChaCha20-Poly1305 AEAD)
module NovaNet.FFI.Crypto
  ( -- * Constants
    cryptoKeySize,
    cryptoNonceSize,
    cryptoTagSize,
    cryptoOverhead,

    -- * Error codes
    CryptoResult (..),

    -- * Operations
    encrypt,
    decrypt,
  )
where

import Data.Word (Word32, Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

-- | Encryption key size (256-bit).
cryptoKeySize :: Int
cryptoKeySize = 32

-- | Nonce counter on wire.
cryptoNonceSize :: Int
cryptoNonceSize = 8

-- | Poly1305 auth tag size.
cryptoTagSize :: Int
cryptoTagSize = 16

-- | Total encryption overhead: nonce + tag = 24 bytes.
cryptoOverhead :: Int
cryptoOverhead = cryptoNonceSize + cryptoTagSize

-- | Crypto operation result.
data CryptoResult
  = CryptoOk
  | CryptoErrKey
  | CryptoErrAuth
  | CryptoErrShort
  | CryptoErrUnknown !CInt
  deriving (Eq, Show)

fromCInt :: CInt -> CryptoResult
fromCInt 0 = CryptoOk
fromCInt (-1) = CryptoErrKey
fromCInt (-2) = CryptoErrAuth
fromCInt (-3) = CryptoErrShort
fromCInt n = CryptoErrUnknown n
{-# INLINE fromCInt #-}

foreign import ccall unsafe "nn_ffi_encrypt"
  c_encrypt :: Ptr Word8 -> Word64 -> Word32 -> Ptr Word8 -> CSize -> IO CInt

foreign import ccall unsafe "nn_ffi_decrypt"
  c_decrypt :: Ptr Word8 -> Word32 -> Ptr Word8 -> CSize -> Ptr Word64 -> Ptr CSize -> IO CInt

-- | Encrypt in place. Returns total output length or error.
encrypt :: Ptr Word8 -> Word64 -> Word32 -> Ptr Word8 -> Int -> IO (Either CryptoResult Int)
encrypt key counter protocolId buf plainLen = do
  rc <- c_encrypt key counter protocolId buf (fromIntegral plainLen)
  return $ if rc > 0 then Right (fromIntegral rc) else Left (fromCInt rc)
{-# INLINE encrypt #-}

-- | Decrypt in place. Returns (counter, plaintext length) or error.
decrypt :: Ptr Word8 -> Word32 -> Ptr Word8 -> Int -> IO (Either CryptoResult (Word64, Int))
decrypt key protocolId buf totalLen =
  alloca $ \counterPtr ->
    alloca $ \lenPtr -> do
      rc <- c_decrypt key protocolId buf (fromIntegral totalLen) counterPtr lenPtr
      if rc /= 0
        then return (Left (fromCInt rc))
        else do
          counter <- peek counterPtr
          pLen <- peek lenPtr
          return (Right (counter, fromIntegral pLen))
{-# INLINE decrypt #-}
