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
    module NovaNet.FFI.Rtt,
    module NovaNet.FFI.SentBuf,
    module NovaNet.FFI.LossWindow,
    module NovaNet.FFI.AckProcess,
    module NovaNet.FFI.Congestion,
    module NovaNet.FFI.RecvBuf,

    -- * Protocol modules
    module NovaNet.Reliability,
    module NovaNet.Channel,
    module NovaNet.Congestion,
    module NovaNet.Connection,
  )
where

import NovaNet.Channel
import NovaNet.Class
import NovaNet.Config
import NovaNet.Congestion
import NovaNet.Connection
import NovaNet.FFI.AckProcess
import NovaNet.FFI.Bandwidth
import NovaNet.FFI.Batch
import NovaNet.FFI.CRC32C
import NovaNet.FFI.Congestion
import NovaNet.FFI.Crypto
import NovaNet.FFI.Fragment
import NovaNet.FFI.LossWindow
import NovaNet.FFI.Packet
import NovaNet.FFI.RecvBuf
import NovaNet.FFI.Rtt
import NovaNet.FFI.SentBuf
import NovaNet.FFI.Seq
import NovaNet.Reliability
import NovaNet.Types
