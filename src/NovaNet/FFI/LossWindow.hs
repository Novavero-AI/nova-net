-- |
-- Module      : NovaNet.FFI.LossWindow
-- Description : FFI bindings to nn_loss_window (rolling loss tracker)
module NovaNet.FFI.LossWindow
  ( LossWindow,
    newLossWindow,
    lossPercent,
    withLossWindow,
  )
where

import Foreign.C.Types (CDouble (..), CSize (..))
import Foreign.ForeignPtr (ForeignPtr, mallocForeignPtrBytes, withForeignPtr)
import Foreign.Ptr (Ptr)

-- | Opaque loss window backed by a C struct.
newtype LossWindow = LossWindow (ForeignPtr ())

foreign import ccall unsafe "nn_ffi_loss_window_size"
  c_loss_window_size :: IO CSize

foreign import ccall unsafe "nn_ffi_loss_window_init"
  c_loss_window_init :: Ptr () -> IO ()

foreign import ccall unsafe "nn_ffi_loss_window_percent"
  c_loss_window_percent :: Ptr () -> IO CDouble

-- | Create a new loss window (all samples clear).
newLossWindow :: IO LossWindow
newLossWindow = do
  sz <- c_loss_window_size
  fptr <- mallocForeignPtrBytes (fromIntegral sz)
  withForeignPtr fptr c_loss_window_init
  return (LossWindow fptr)

-- | Current loss fraction (0.0 to 1.0).
lossPercent :: LossWindow -> IO Double
lossPercent (LossWindow fptr) =
  withForeignPtr fptr $ \ptr -> do
    CDouble pct <- c_loss_window_percent ptr
    return pct
{-# INLINE lossPercent #-}

-- | Access the underlying pointer (for passing to ack_process).
withLossWindow :: LossWindow -> (Ptr () -> IO a) -> IO a
withLossWindow (LossWindow fptr) = withForeignPtr fptr
{-# INLINE withLossWindow #-}
