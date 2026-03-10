-- |
-- Module      : NovaNet.FFI.RecvBuf
-- Description : FFI bindings to nn_recv_buf (received packet deduplication)
module NovaNet.FFI.RecvBuf
  ( RecvBuf,
    newRecvBuf,
    recvBufExists,
    recvBufInsert,
    recvBufHighest,
    withRecvBuf,
  )
where

import Data.Word (Word16)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr)

-- | Opaque received packet buffer backed by a C ring buffer.
newtype RecvBuf = RecvBuf (ForeignPtr ())

foreign import ccall unsafe "nn_ffi_recv_buf_size"
  c_recv_buf_size :: IO CSize

foreign import ccall unsafe "nn_ffi_recv_buf_init"
  c_recv_buf_init :: Ptr () -> IO ()

foreign import ccall unsafe "nn_ffi_recv_buf_exists"
  c_recv_buf_exists :: Ptr () -> Word16 -> IO CInt

foreign import ccall unsafe "nn_ffi_recv_buf_insert"
  c_recv_buf_insert :: Ptr () -> Word16 -> IO ()

foreign import ccall unsafe "nn_ffi_recv_buf_highest"
  c_recv_buf_highest :: Ptr () -> IO Word16

-- | Create a new empty receive buffer.
newRecvBuf :: IO RecvBuf
newRecvBuf = do
  sz <- c_recv_buf_size
  fptr <- mallocForeignPtrBytes (fromIntegral sz)
  withForeignPtr fptr c_recv_buf_init
  return (RecvBuf fptr)

-- | Check if a sequence number was previously received (dedup).
recvBufExists :: RecvBuf -> Word16 -> IO Bool
recvBufExists (RecvBuf fptr) seq_ =
  withForeignPtr fptr $ \ptr ->
    (/= 0) <$> c_recv_buf_exists ptr seq_
{-# INLINE recvBufExists #-}

-- | Record a received sequence number.
recvBufInsert :: RecvBuf -> Word16 -> IO ()
recvBufInsert (RecvBuf fptr) seq_ =
  withForeignPtr fptr $ \ptr -> c_recv_buf_insert ptr seq_
{-# INLINE recvBufInsert #-}

-- | Highest received sequence number.
recvBufHighest :: RecvBuf -> IO Word16
recvBufHighest (RecvBuf fptr) =
  withForeignPtr fptr c_recv_buf_highest
{-# INLINE recvBufHighest #-}

-- | Access the underlying pointer.
withRecvBuf :: RecvBuf -> (Ptr () -> IO a) -> IO a
withRecvBuf (RecvBuf fptr) = withForeignPtr fptr
{-# INLINE withRecvBuf #-}
