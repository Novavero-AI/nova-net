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
    module NovaNet.FFI.SipHash,
    module NovaNet.FFI.Random,

    -- * Protocol modules
    module NovaNet.Reliability,
    module NovaNet.Channel,
    module NovaNet.Congestion,
    module NovaNet.Connection,

    -- * Subsystems
    module NovaNet.Fragment,
    module NovaNet.Mtu,
    module NovaNet.Security,
    module NovaNet.Stats,

    -- * Peer layer
    module NovaNet.Peer,
    module NovaNet.Peer.Protocol,
    module NovaNet.Peer.Handshake,
    module NovaNet.Peer.Migration,
    module NovaNet.Net,

    -- * Replication
    module NovaNet.Replication.Delta,
    module NovaNet.Replication.Interest,
    module NovaNet.Replication.Priority,
    module NovaNet.Replication.Interpolation,

    -- * Testing
    module NovaNet.TestNet,
    module NovaNet.Simulator,
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
import NovaNet.FFI.Random
import NovaNet.FFI.RecvBuf
import NovaNet.FFI.Rtt
import NovaNet.FFI.SentBuf
import NovaNet.FFI.Seq
import NovaNet.FFI.SipHash
import NovaNet.Fragment
import NovaNet.Mtu
import NovaNet.Net
import NovaNet.Peer
import NovaNet.Peer.Handshake
import NovaNet.Peer.Migration
import NovaNet.Peer.Protocol
import NovaNet.Reliability
import NovaNet.Replication.Delta
import NovaNet.Replication.Interest
import NovaNet.Replication.Interpolation
import NovaNet.Replication.Priority
import NovaNet.Security
import NovaNet.Simulator
import NovaNet.Stats
import NovaNet.TestNet
import NovaNet.Types
