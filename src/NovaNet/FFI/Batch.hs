-- |
-- Module      : NovaNet.FFI.Batch
-- Description : FFI bindings to nn_batch (message batching)
--
-- Batch operations use the C writer/reader structs directly through
-- opaque pointers. For the Haskell protocol brain, batching is done
-- at a higher level — these bindings exist for direct buffer manipulation.
module NovaNet.FFI.Batch
  ( batchHeaderSize,
    batchLengthSize,
  )
where

-- | Batch header overhead: 1 byte for message count.
batchHeaderSize :: Int
batchHeaderSize = 1

-- | Per-message length prefix: 2 bytes (uint16 LE).
batchLengthSize :: Int
batchLengthSize = 2

-- NOTE: The batch writer/reader use C structs with internal state
-- (offset, count). For the Haskell side, we'll either:
--   1. Implement batching in pure Haskell (simple enough)
--   2. Add flat FFI wrappers when needed for the pipeline
-- For now, the constants are what the protocol brain needs.
