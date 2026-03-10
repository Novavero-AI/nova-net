-- |
-- Module      : NovaNet.Stats
-- Description : Network statistics, quality assessment, and transport counters
--
-- Pure data types for aggregating network metrics.  Connection quality
-- assessment derives a grade from RTT and packet loss.  Socket-level
-- stats track raw transport counters.  The Peer layer (Phase 4)
-- gathers these from subsystem state.
module NovaNet.Stats
  ( -- * Connection Quality
    ConnectionQuality (..),
    assessQuality,

    -- * Congestion Level
    CongestionLevel (..),

    -- * Network Stats (aggregate)
    NetworkStats (..),
    defaultNetworkStats,

    -- * Socket Stats (transport counters)
    SocketStats (..),
    defaultSocketStats,
    recordSocketSend,
    recordSocketRecv,
    recordCrcDrop,
    recordDecryptFailure,
  )
where

import Data.Word (Word64)

-- ---------------------------------------------------------------------------
-- Quality assessment constants
-- ---------------------------------------------------------------------------

-- | RTT threshold for Bad quality (milliseconds).
rttBadMs :: Double
rttBadMs = 500.0

-- | RTT threshold for Poor quality.
rttPoorMs :: Double
rttPoorMs = 250.0

-- | RTT threshold for Fair quality.
rttFairMs :: Double
rttFairMs = 150.0

-- | RTT threshold for Good quality.
rttGoodMs :: Double
rttGoodMs = 80.0

-- | Loss threshold for Bad quality (percentage).
lossBadPct :: Double
lossBadPct = 10.0

-- | Loss threshold for Poor quality.
lossPoorPct :: Double
lossPoorPct = 5.0

-- | Loss threshold for Fair quality.
lossFairPct :: Double
lossFairPct = 2.0

-- | Loss threshold for Good quality.
lossGoodPct :: Double
lossGoodPct = 0.5

-- ---------------------------------------------------------------------------
-- Connection Quality
-- ---------------------------------------------------------------------------

-- | Overall connection quality grade, derived from RTT and packet loss.
data ConnectionQuality
  = QualityExcellent
  | QualityGood
  | QualityFair
  | QualityPoor
  | QualityBad
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Assess connection quality from RTT (milliseconds) and packet loss
-- (percentage, 0-100).  The worst of the two metrics determines the grade.
assessQuality :: Double -> Double -> ConnectionQuality
assessQuality rttMs lossPct
  | rttMs > rttBadMs || lossPct > lossBadPct = QualityBad
  | rttMs > rttPoorMs || lossPct > lossPoorPct = QualityPoor
  | rttMs > rttFairMs || lossPct > lossFairPct = QualityFair
  | rttMs > rttGoodMs || lossPct > lossGoodPct = QualityGood
  | otherwise = QualityExcellent

-- ---------------------------------------------------------------------------
-- Congestion Level
-- ---------------------------------------------------------------------------

-- | Current congestion state, reported by the congestion controller.
data CongestionLevel
  = CongestionNone
  | CongestionElevated
  | CongestionHigh
  | CongestionCritical
  deriving (Eq, Ord, Show, Enum, Bounded)

-- ---------------------------------------------------------------------------
-- Network Stats (aggregate)
-- ---------------------------------------------------------------------------

-- | Aggregate network statistics for a connection.  Gathered by the
-- Peer layer from subsystem state (Reliability, Bandwidth, Congestion).
data NetworkStats = NetworkStats
  { nsPacketsSent :: !Word64,
    nsPacketsReceived :: !Word64,
    nsBytesSent :: !Word64,
    nsBytesReceived :: !Word64,
    nsRttMs :: !Double,
    nsPacketLossPercent :: !Double,
    nsBandwidthUpBps :: !Double,
    nsBandwidthDownBps :: !Double,
    nsQuality :: !ConnectionQuality,
    nsCongestionLevel :: !CongestionLevel,
    nsFragmentsCompleted :: !Word64,
    nsFragmentsTimedOut :: !Word64
  }
  deriving (Show)

-- | All-zero initial stats.
defaultNetworkStats :: NetworkStats
defaultNetworkStats =
  NetworkStats
    { nsPacketsSent = 0,
      nsPacketsReceived = 0,
      nsBytesSent = 0,
      nsBytesReceived = 0,
      nsRttMs = 0.0,
      nsPacketLossPercent = 0.0,
      nsBandwidthUpBps = 0.0,
      nsBandwidthDownBps = 0.0,
      nsQuality = QualityExcellent,
      nsCongestionLevel = CongestionNone,
      nsFragmentsCompleted = 0,
      nsFragmentsTimedOut = 0
    }

-- ---------------------------------------------------------------------------
-- Socket Stats (transport counters)
-- ---------------------------------------------------------------------------

-- | Raw transport-level counters for a socket.
data SocketStats = SocketStats
  { ssPacketsSent :: !Word64,
    ssPacketsReceived :: !Word64,
    ssBytesSent :: !Word64,
    ssBytesReceived :: !Word64,
    ssCrcDrops :: !Word64,
    ssDecryptFailures :: !Word64
  }
  deriving (Show)

-- | All-zero initial counters.
defaultSocketStats :: SocketStats
defaultSocketStats =
  SocketStats
    { ssPacketsSent = 0,
      ssPacketsReceived = 0,
      ssBytesSent = 0,
      ssBytesReceived = 0,
      ssCrcDrops = 0,
      ssDecryptFailures = 0
    }

-- | Record an outgoing packet.
recordSocketSend :: Int -> SocketStats -> SocketStats
recordSocketSend bytes ss =
  ss
    { ssPacketsSent = ssPacketsSent ss + 1,
      ssBytesSent = ssBytesSent ss + fromIntegral bytes
    }

-- | Record an incoming packet.
recordSocketRecv :: Int -> SocketStats -> SocketStats
recordSocketRecv bytes ss =
  ss
    { ssPacketsReceived = ssPacketsReceived ss + 1,
      ssBytesReceived = ssBytesReceived ss + fromIntegral bytes
    }

-- | Record a CRC validation failure.
recordCrcDrop :: SocketStats -> SocketStats
recordCrcDrop ss = ss {ssCrcDrops = ssCrcDrops ss + 1}

-- | Record a decryption failure.
recordDecryptFailure :: SocketStats -> SocketStats
recordDecryptFailure ss = ss {ssDecryptFailures = ssDecryptFailures ss + 1}
