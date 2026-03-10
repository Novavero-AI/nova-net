-- |
-- Module      : NovaNet.FFI.Batch
-- Description : FFI bindings to nn_batch (message batching)
module NovaNet.FFI.Batch
  ( batchHeaderSize,
    batchLengthSize,
    batchMaxMessages,
  )
where

-- | Batch header overhead: 1 byte for message count.
batchHeaderSize :: Int
batchHeaderSize = 1

-- | Per-message length prefix: 2 bytes (uint16 LE).
batchLengthSize :: Int
batchLengthSize = 2

-- | Maximum messages per batch.
batchMaxMessages :: Int
batchMaxMessages = 255
