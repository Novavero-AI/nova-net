-- |
-- Module      : NovaNet
-- Description : General-purpose reliable UDP networking
--
-- C99 hot path for maximum performance. Haskell protocol brain for
-- correct-by-construction logic. Successor to gbnet-hs.
module NovaNet
  ( -- * Types
    module NovaNet.Types,

    -- * Effect classes
    module NovaNet.Class,

    -- * Configuration
    module NovaNet.Config,

    -- * FFI (low-level)
    module NovaNet.FFI.Packet,
    module NovaNet.FFI.CRC32C,
    module NovaNet.FFI.Seq,
    module NovaNet.FFI.Fragment,
    module NovaNet.FFI.Batch,
    module NovaNet.FFI.Crypto,
    module NovaNet.FFI.Bandwidth,
  )
where

import NovaNet.Class
import NovaNet.Config
import NovaNet.FFI.Bandwidth
import NovaNet.FFI.Batch
import NovaNet.FFI.CRC32C
import NovaNet.FFI.Crypto
import NovaNet.FFI.Fragment
import NovaNet.FFI.Packet
import NovaNet.FFI.Seq
import NovaNet.Types
