-- |
-- Module      : NovaNet.FFI.Fragment
-- Description : FFI bindings to nn_fragment (message fragmentation)
module NovaNet.FFI.Fragment
  ( fragmentHeaderSize,
    maxFragmentCount,
    fragmentWrite,
    fragmentRead,
    fragmentCount,
    fragmentBuild,
  )
where

import Data.Word (Word32, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

-- | Fragment header size in bytes.
fragmentHeaderSize :: Int
fragmentHeaderSize = 6

-- | Maximum fragments per message.
maxFragmentCount :: Int
maxFragmentCount = 255

foreign import ccall unsafe "nn_ffi_fragment_write"
  c_fragment_write :: Word32 -> Word8 -> Word8 -> Ptr Word8 -> IO CInt

foreign import ccall unsafe "nn_ffi_fragment_read"
  c_fragment_read :: Ptr Word8 -> CSize -> Ptr Word32 -> Ptr Word8 -> Ptr Word8 -> IO CInt

foreign import ccall unsafe "nn_ffi_fragment_count"
  c_fragment_count :: CSize -> CSize -> IO CInt

foreign import ccall unsafe "nn_ffi_fragment_build"
  c_fragment_build :: Ptr Word8 -> CSize -> Word32 -> Word8 -> Word8 -> CSize -> Ptr Word8 -> IO CInt

-- | Write fragment header. Returns bytes written (always 6).
fragmentWrite :: Word32 -> Word8 -> Word8 -> Ptr Word8 -> IO Int
fragmentWrite msgId idx cnt buf = fromIntegral <$> c_fragment_write msgId idx cnt buf
{-# INLINE fragmentWrite #-}

-- | Read fragment header.
fragmentRead :: Ptr Word8 -> Int -> IO (Maybe (Word32, Word8, Word8))
fragmentRead buf len =
  alloca $ \midPtr ->
    alloca $ \idxPtr ->
      alloca $ \cntPtr -> do
        rc <- c_fragment_read buf (fromIntegral len) midPtr idxPtr cntPtr
        if rc /= 0
          then return Nothing
          else do
            mid <- peek midPtr
            idx <- peek idxPtr
            cnt <- peek cntPtr
            return (Just (mid, idx, cnt))
{-# INLINE fragmentRead #-}

-- | Compute fragment count. Returns Nothing if too many.
fragmentCount :: Int -> Int -> IO (Maybe Int)
fragmentCount msgLen maxPayload = do
  rc <- c_fragment_count (fromIntegral msgLen) (fromIntegral maxPayload)
  return $ if rc < 0 then Nothing else Just (fromIntegral rc)
{-# INLINE fragmentCount #-}

-- | Build one fragment (header + payload). Returns bytes written.
fragmentBuild :: Ptr Word8 -> Int -> Word32 -> Word8 -> Word8 -> Int -> Ptr Word8 -> IO (Maybe Int)
fragmentBuild msg msgLen msgId fragIdx fragCnt maxPayload outBuf = do
  rc <- c_fragment_build msg (fromIntegral msgLen) msgId fragIdx fragCnt (fromIntegral maxPayload) outBuf
  return $ if rc < 0 then Nothing else Just (fromIntegral rc)
{-# INLINE fragmentBuild #-}
