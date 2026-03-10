-- |
-- Module      : NovaNet.FFI.SentBuf
-- Description : FFI bindings to nn_sent_buf (sent packet ring buffer)
module NovaNet.FFI.SentBuf
  ( SentBuf,
    newSentBuf,
    sentBufInsert,
    sentBufCount,
    withSentBuf,
  )
where

import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr)

-- | Opaque sent packet buffer backed by a C struct.
newtype SentBuf = SentBuf (ForeignPtr ())

foreign import ccall unsafe "nn_ffi_sent_buf_size"
  c_sent_buf_size :: IO CSize

foreign import ccall unsafe "nn_ffi_sent_buf_init"
  c_sent_buf_init :: Ptr () -> IO ()

foreign import ccall unsafe "nn_ffi_sent_buf_insert"
  c_sent_buf_insert :: Ptr () -> Word16 -> Word8 -> Word16 -> Word64 -> Word32 -> IO CInt

foreign import ccall unsafe "nn_ffi_sent_buf_count"
  c_sent_buf_count :: Ptr () -> IO CInt

-- | Create a new empty sent buffer.
newSentBuf :: IO SentBuf
newSentBuf = do
  sz <- c_sent_buf_size
  fptr <- mallocForeignPtrBytes (fromIntegral sz)
  withForeignPtr fptr c_sent_buf_init
  return (SentBuf fptr)

-- | Insert a sent record. Returns 1 if a different seq was evicted.
sentBufInsert :: SentBuf -> Word16 -> Word8 -> Word16 -> Word64 -> Word32 -> IO Int
sentBufInsert (SentBuf fptr) seq_ chanId chanSeq sendTime pktSize =
  withForeignPtr fptr $ \ptr ->
    fromIntegral <$> c_sent_buf_insert ptr seq_ chanId chanSeq sendTime pktSize
{-# INLINE sentBufInsert #-}

-- | Number of occupied entries.
sentBufCount :: SentBuf -> IO Int
sentBufCount (SentBuf fptr) =
  withForeignPtr fptr (fmap fromIntegral . c_sent_buf_count)
{-# INLINE sentBufCount #-}

-- | Access the underlying pointer (for passing to ack_process).
withSentBuf :: SentBuf -> (Ptr () -> IO a) -> IO a
withSentBuf (SentBuf fptr) = withForeignPtr fptr
{-# INLINE withSentBuf #-}
