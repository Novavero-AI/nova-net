-- |
-- Module      : NovaNet.FFI.AckProcess
-- Description : FFI bindings to nn_ack_process (ACK bitfield processing)
module NovaNet.FFI.AckProcess
  ( AckResult (..),
    processAcks,
  )
where

import Data.Int (Int32, Int64)
import Data.Word (Word16, Word32, Word64)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)

-- | Result of processing an incoming ACK packet.
data AckResult = AckResult
  { arAckedCount :: !Int32,
    arAckedBytes :: !Int32,
    arRttSampleNs :: !Int64,
    arLostCount :: !Int32,
    arFastRetransmit :: !Bool,
    arRetransmitSeq :: !Word16
  }
  deriving (Eq, Show)

foreign import ccall unsafe "nn_ffi_ack_process"
  c_ack_process ::
    Ptr () ->
    Ptr () ->
    Word16 ->
    Word32 ->
    Word64 ->
    Ptr Int32 ->
    Ptr Int32 ->
    Ptr Int64 ->
    Ptr Int32 ->
    Ptr CInt ->
    Ptr Word16 ->
    IO ()

-- | Process an incoming ACK against the sent buffer and loss window.
processAcks ::
  Ptr () ->
  Ptr () ->
  Word16 ->
  Word32 ->
  Word64 ->
  IO AckResult
processAcks sentPtr lwPtr ackSeq ackBitfield nowNs =
  alloca $ \ackedCountPtr ->
    alloca $ \ackedBytesPtr ->
      alloca $ \rttPtr ->
        alloca $ \lostPtr ->
          alloca $ \fastPtr ->
            alloca $ \retransPtr -> do
              c_ack_process
                sentPtr
                lwPtr
                ackSeq
                ackBitfield
                nowNs
                ackedCountPtr
                ackedBytesPtr
                rttPtr
                lostPtr
                fastPtr
                retransPtr
              AckResult
                <$> peek ackedCountPtr
                <*> peek ackedBytesPtr
                <*> peek rttPtr
                <*> peek lostPtr
                <*> ((/= 0) <$> peek fastPtr)
                <*> peek retransPtr
{-# INLINE processAcks #-}
