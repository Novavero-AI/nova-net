-- |
-- Module      : NovaNet.FFI.Congestion
-- Description : FFI bindings to nn_congestion (dual-layer congestion control)
module NovaNet.FFI.Congestion
  ( -- * AIMD controller
    AimdController,
    newAimdController,
    aimdTick,
    aimdCanSend,
    aimdDeduct,
    aimdRate,

    -- * CWND controller
    CwndController,
    newCwndController,
    cwndOnAck,
    cwndOnLoss,
    cwndCanSend,
    cwndOnSend,
    cwndPacingNs,
    cwndCheckIdle,
    cwndOnAckSeq,
    cwndSetSrtt,
  )
where

import Data.Int (Int32, Int64)
import Data.Word (Word16, Word32)
import Foreign.C.Types (CDouble (..), CInt (..), CSize (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr)

-- ---------------------------------------------------------------------------
-- AIMD
-- ---------------------------------------------------------------------------

-- | Opaque AIMD congestion controller.
newtype AimdController = AimdController (ForeignPtr ())

foreign import ccall unsafe "nn_ffi_cong_aimd_size"
  c_aimd_size :: IO CSize

foreign import ccall unsafe "nn_ffi_cong_aimd_init"
  c_aimd_init :: Ptr () -> CDouble -> CDouble -> Int64 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_aimd_tick"
  c_aimd_tick :: Ptr () -> CDouble -> CDouble -> Int64 -> Int64 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_aimd_can_send"
  c_aimd_can_send :: Ptr () -> IO CInt

foreign import ccall unsafe "nn_ffi_cong_aimd_deduct"
  c_aimd_deduct :: Ptr () -> IO ()

foreign import ccall unsafe "nn_ffi_cong_aimd_rate"
  c_aimd_rate :: Ptr () -> IO CDouble

-- | Create a new AIMD controller.
newAimdController :: Double -> Double -> Int64 -> IO AimdController
newAimdController baseRate lossThresh rttThreshNs = do
  sz <- c_aimd_size
  fptr <- mallocForeignPtrBytes (fromIntegral sz)
  withForeignPtr fptr $ \ptr ->
    c_aimd_init ptr (CDouble baseRate) (CDouble lossThresh) rttThreshNs
  return (AimdController fptr)

-- | Per-tick update.
aimdTick :: AimdController -> Double -> Double -> Int64 -> Int64 -> IO ()
aimdTick (AimdController fptr) dtSec lossFrac srttNs nowNs =
  withForeignPtr fptr $ \ptr ->
    c_aimd_tick ptr (CDouble dtSec) (CDouble lossFrac) srttNs nowNs
{-# INLINE aimdTick #-}

-- | Can we send a packet?
aimdCanSend :: AimdController -> IO Bool
aimdCanSend (AimdController fptr) =
  withForeignPtr fptr (fmap (/= 0) . c_aimd_can_send)
{-# INLINE aimdCanSend #-}

-- | Deduct one packet from budget.
aimdDeduct :: AimdController -> IO ()
aimdDeduct (AimdController fptr) =
  withForeignPtr fptr c_aimd_deduct
{-# INLINE aimdDeduct #-}

-- | Current send rate in packets/sec.
aimdRate :: AimdController -> IO Double
aimdRate (AimdController fptr) =
  withForeignPtr fptr $ \ptr -> do
    CDouble r <- c_aimd_rate ptr
    return r
{-# INLINE aimdRate #-}

-- ---------------------------------------------------------------------------
-- CWND
-- ---------------------------------------------------------------------------

-- | Opaque TCP-like congestion window controller.
newtype CwndController = CwndController (ForeignPtr ())

foreign import ccall unsafe "nn_ffi_cong_cwnd_size"
  c_cwnd_size :: IO CSize

foreign import ccall unsafe "nn_ffi_cong_cwnd_init"
  c_cwnd_init :: Ptr () -> Word32 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_cwnd_on_ack"
  c_cwnd_on_ack :: Ptr () -> Int32 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_cwnd_on_loss"
  c_cwnd_on_loss :: Ptr () -> Word16 -> Int64 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_cwnd_can_send"
  c_cwnd_can_send :: Ptr () -> Int32 -> IO CInt

foreign import ccall unsafe "nn_ffi_cong_cwnd_on_send"
  c_cwnd_on_send :: Ptr () -> Int32 -> Int64 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_cwnd_pacing_ns"
  c_cwnd_pacing_ns :: Ptr () -> IO Int64

foreign import ccall unsafe "nn_ffi_cong_cwnd_check_idle"
  c_cwnd_check_idle :: Ptr () -> Int64 -> Int64 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_cwnd_on_ack_seq"
  c_cwnd_on_ack_seq :: Ptr () -> Word16 -> Int32 -> IO ()

foreign import ccall unsafe "nn_ffi_cong_cwnd_set_srtt"
  c_cwnd_set_srtt :: Ptr () -> Int64 -> IO ()

-- | Create a new CWND controller with the given MSS.
newCwndController :: Word32 -> IO CwndController
newCwndController mss = do
  sz <- c_cwnd_size
  fptr <- mallocForeignPtrBytes (fromIntegral sz)
  withForeignPtr fptr $ \ptr -> c_cwnd_init ptr mss
  return (CwndController fptr)

-- | Process acked bytes (grow window).
cwndOnAck :: CwndController -> Int32 -> IO ()
cwndOnAck (CwndController fptr) ackedBytes =
  withForeignPtr fptr $ \ptr -> c_cwnd_on_ack ptr ackedBytes
{-# INLINE cwndOnAck #-}

-- | Process a loss event.
cwndOnLoss :: CwndController -> Word16 -> Int64 -> IO ()
cwndOnLoss (CwndController fptr) lossSeq nowNs =
  withForeignPtr fptr $ \ptr -> c_cwnd_on_loss ptr lossSeq nowNs
{-# INLINE cwndOnLoss #-}

-- | Can we send a packet of this size?
cwndCanSend :: CwndController -> Int32 -> IO Bool
cwndCanSend (CwndController fptr) pktSize =
  withForeignPtr fptr $ \ptr ->
    (/= 0) <$> c_cwnd_can_send ptr pktSize
{-# INLINE cwndCanSend #-}

-- | Record a sent packet.
cwndOnSend :: CwndController -> Int32 -> Int64 -> IO ()
cwndOnSend (CwndController fptr) pktSize nowNs =
  withForeignPtr fptr $ \ptr -> c_cwnd_on_send ptr pktSize nowNs
{-# INLINE cwndOnSend #-}

-- | Pacing interval in nanoseconds. 0 = no pacing.
cwndPacingNs :: CwndController -> IO Int64
cwndPacingNs (CwndController fptr) =
  withForeignPtr fptr c_cwnd_pacing_ns
{-# INLINE cwndPacingNs #-}

-- | Check for idle restart.
cwndCheckIdle :: CwndController -> Int64 -> Int64 -> IO ()
cwndCheckIdle (CwndController fptr) nowNs rtoNs =
  withForeignPtr fptr $ \ptr -> c_cwnd_check_idle ptr nowNs rtoNs
{-# INLINE cwndCheckIdle #-}

-- | Process acked sequence (in-flight + recovery exit).
cwndOnAckSeq :: CwndController -> Word16 -> Int32 -> IO ()
cwndOnAckSeq (CwndController fptr) ackedSeq ackedBytes =
  withForeignPtr fptr $ \ptr -> c_cwnd_on_ack_seq ptr ackedSeq ackedBytes
{-# INLINE cwndOnAckSeq #-}

-- | Update cached SRTT for pacing calculation.
cwndSetSrtt :: CwndController -> Int64 -> IO ()
cwndSetSrtt (CwndController fptr) srttNs =
  withForeignPtr fptr $ \ptr -> c_cwnd_set_srtt ptr srttNs
{-# INLINE cwndSetSrtt #-}
