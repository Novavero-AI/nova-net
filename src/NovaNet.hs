-- |
-- Module      : NovaNet
-- Description : General-purpose reliable UDP networking
--
-- C99 hot path for maximum performance. Haskell protocol brain for
-- correct-by-construction logic. Successor to gbnet-hs.
module NovaNet
  ( -- * Types
    module NovaNet.Types,

    -- * FFI (low-level)
    module NovaNet.FFI.Packet,
    module NovaNet.FFI.CRC32C,
    module NovaNet.FFI.Seq,
    module NovaNet.FFI.Fragment,
    module NovaNet.FFI.Crypto,
    module NovaNet.FFI.Bandwidth,
  )
where

import NovaNet.FFI.Bandwidth
import NovaNet.FFI.CRC32C
import NovaNet.FFI.Crypto
import NovaNet.FFI.Fragment
import NovaNet.FFI.Packet
import NovaNet.FFI.Seq
import NovaNet.Types
