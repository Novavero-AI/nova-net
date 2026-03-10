-- |
-- Module      : NovaNet.FFI.Rtt
-- Description : FFI bindings to nn_rtt (Jacobson/Karels RTT estimation)
module NovaNet.FFI.Rtt
  ( RttEstimator,
    newRttEstimator,
    rttUpdate,
    rttGetRto,
    rttGetSrtt,
  )
where

import Data.Int (Int64)
import Foreign.C.Types (CSize (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr)

-- | Opaque RTT estimator backed by a C struct.
newtype RttEstimator = RttEstimator (ForeignPtr ())

foreign import ccall unsafe "nn_ffi_rtt_size"
  c_rtt_size :: IO CSize

foreign import ccall unsafe "nn_ffi_rtt_init"
  c_rtt_init :: Ptr () -> IO ()

foreign import ccall unsafe "nn_ffi_rtt_update"
  c_rtt_update :: Ptr () -> Int64 -> IO ()

foreign import ccall unsafe "nn_ffi_rtt_rto"
  c_rtt_rto :: Ptr () -> IO Int64

foreign import ccall unsafe "nn_ffi_rtt_srtt"
  c_rtt_srtt :: Ptr () -> IO Int64

-- | Create a new RTT estimator (uninitialized, RTO = max).
newRttEstimator :: IO RttEstimator
newRttEstimator = do
  sz <- c_rtt_size
  fptr <- mallocForeignPtrBytes (fromIntegral sz)
  withForeignPtr fptr c_rtt_init
  return (RttEstimator fptr)

-- | Feed one RTT sample in nanoseconds.
rttUpdate :: RttEstimator -> Int64 -> IO ()
rttUpdate (RttEstimator fptr) sampleNs =
  withForeignPtr fptr $ \ptr -> c_rtt_update ptr sampleNs
{-# INLINE rttUpdate #-}

-- | Get current retransmission timeout in nanoseconds.
rttGetRto :: RttEstimator -> IO Int64
rttGetRto (RttEstimator fptr) =
  withForeignPtr fptr c_rtt_rto
{-# INLINE rttGetRto #-}

-- | Get current smoothed RTT in nanoseconds.
rttGetSrtt :: RttEstimator -> IO Int64
rttGetSrtt (RttEstimator fptr) =
  withForeignPtr fptr c_rtt_srtt
{-# INLINE rttGetSrtt #-}
