-- |
-- Module      : NovaNet.FFI.Bandwidth
-- Description : FFI bindings to nn_bandwidth (sliding window tracker)
module NovaNet.FFI.Bandwidth
  ( BandwidthTracker,
    newBandwidthTracker,
    bandwidthRecord,
    bandwidthBps,
  )
where

import Data.Word (Word32, Word64)
import Foreign.C.Types (CDouble (..), CSize (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr)

-- | Opaque bandwidth tracker backed by a C struct.
newtype BandwidthTracker = BandwidthTracker (ForeignPtr ())

foreign import ccall unsafe "nn_ffi_bandwidth_size"
  c_bandwidth_size :: IO CSize

foreign import ccall unsafe "nn_ffi_bandwidth_init"
  c_bandwidth_init :: Ptr () -> CDouble -> IO ()

foreign import ccall unsafe "nn_ffi_bandwidth_record"
  c_bandwidth_record :: Ptr () -> Word32 -> Word64 -> IO ()

foreign import ccall unsafe "nn_ffi_bandwidth_bps"
  c_bandwidth_bps :: Ptr () -> Word64 -> IO CDouble

-- | Create a new bandwidth tracker with the given window in milliseconds.
newBandwidthTracker :: Double -> IO BandwidthTracker
newBandwidthTracker windowMs = do
  sz <- c_bandwidth_size
  fptr <- mallocForeignPtrBytes (fromIntegral sz)
  withForeignPtr fptr $ \ptr -> c_bandwidth_init ptr (CDouble windowMs)
  return (BandwidthTracker fptr)

-- | Record a transfer of @size@ bytes at the given nanosecond timestamp.
bandwidthRecord :: BandwidthTracker -> Word32 -> Word64 -> IO ()
bandwidthRecord (BandwidthTracker fptr) size nowNs =
  withForeignPtr fptr $ \ptr -> c_bandwidth_record ptr size nowNs
{-# INLINE bandwidthRecord #-}

-- | Get current bytes per second.
bandwidthBps :: BandwidthTracker -> Word64 -> IO Double
bandwidthBps (BandwidthTracker fptr) nowNs =
  withForeignPtr fptr $ \ptr -> do
    CDouble bps <- c_bandwidth_bps ptr nowNs
    return bps
{-# INLINE bandwidthBps #-}
