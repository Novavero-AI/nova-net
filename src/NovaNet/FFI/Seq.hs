-- |
-- Module      : NovaNet.FFI.Seq
-- Description : FFI bindings to nn_seq (sequence numbers)
module NovaNet.FFI.Seq
  ( seqGt,
    seqDiff,
  )
where

import Data.Int (Int32)
import Data.Word (Word16)
import Foreign.C.Types (CInt (..))

foreign import ccall unsafe "nn_ffi_seq_gt"
  c_seq_gt :: Word16 -> Word16 -> IO CInt

foreign import ccall unsafe "nn_ffi_seq_diff"
  c_seq_diff :: Word16 -> Word16 -> IO Int32

-- | Wraparound-safe greater-than comparison.
seqGt :: Word16 -> Word16 -> IO Bool
seqGt s1 s2 = (/= 0) <$> c_seq_gt s1 s2
{-# INLINE seqGt #-}

-- | Signed difference accounting for wraparound.
seqDiff :: Word16 -> Word16 -> IO Int32
seqDiff = c_seq_diff
{-# INLINE seqDiff #-}
