-- |
-- Module      : NovaNet.Config
-- Description : Network configuration with validation
--
-- All tunable parameters for the networking stack. Every threshold,
-- timeout, and limit gets a name. Validation catches invalid configs
-- before they cause runtime failures.
module NovaNet.Config
  ( -- * Configuration
    NetworkConfig (..),
    defaultNetworkConfig,
    ChannelConfig (..),
    defaultChannelConfig,
    SimulationConfig (..),

    -- * Validation
    ConfigField (..),
    ConfigError (..),
    validateConfig,
  )
where

import Data.Word (Word16, Word32, Word8)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Channel configuration
-- ---------------------------------------------------------------------------

-- | Per-channel configuration.
data ChannelConfig = ChannelConfig
  { ccDeliveryMode :: !DeliveryMode,
    ccMaxMessageSize :: !Int,
    ccMessageBufferSize :: !Int,
    ccBlockOnFull :: !Bool,
    ccOrderedBufferTimeoutMs :: !Milliseconds,
    ccMaxOrderedBufferSize :: !Int,
    ccMaxReliableRetries :: !Int,
    ccPriority :: !Word8
  }
  deriving (Show)

-- | Sensible defaults: 'ReliableOrdered', 1024-byte messages, 256-entry buffer.
defaultChannelConfig :: ChannelConfig
defaultChannelConfig =
  ChannelConfig
    { ccDeliveryMode = ReliableOrdered,
      ccMaxMessageSize = 1024,
      ccMessageBufferSize = 256,
      ccBlockOnFull = False,
      ccOrderedBufferTimeoutMs = Milliseconds 5000.0,
      ccMaxOrderedBufferSize = 64,
      ccMaxReliableRetries = 10,
      ccPriority = 128
    }

-- ---------------------------------------------------------------------------
-- Simulation configuration
-- ---------------------------------------------------------------------------

-- | Network condition simulation parameters.
data SimulationConfig = SimulationConfig
  { simPacketLoss :: !Double,
    simLatencyMs :: !Milliseconds,
    simJitterMs :: !Milliseconds,
    simDuplicateChance :: !Double,
    simOutOfOrderChance :: !Double,
    simOutOfOrderMaxDelayMs :: !Milliseconds,
    simBandwidthLimitBytesPerSec :: !Int
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Network configuration
-- ---------------------------------------------------------------------------

-- | Top-level network configuration.
data NetworkConfig = NetworkConfig
  { -- Protocol
    ncProtocolId :: !Word32,
    -- Connections
    ncMaxClients :: !Int,
    ncMaxPending :: !Int,
    ncConnectionTimeoutMs :: !Milliseconds,
    ncKeepaliveIntervalMs :: !Milliseconds,
    ncConnectionRequestTimeoutMs :: !Milliseconds,
    ncConnectionRequestMaxRetries :: !Int,
    -- Transport
    ncMtu :: !Int,
    ncSendRate :: !Double,
    ncMaxPacketRate :: !Double,
    -- Fragmentation
    ncFragmentThreshold :: !Int,
    ncFragmentTimeoutMs :: !Milliseconds,
    ncMaxFragments :: !Int,
    ncMaxReassemblyBufferSize :: !Int,
    -- Reliability
    ncPacketBufferSize :: !Int,
    ncAckBufferSize :: !Int,
    ncMaxSequenceDistance :: !Word16,
    ncReliableRetryTimeMs :: !Milliseconds,
    ncMaxReliableRetries :: !Int,
    ncMaxInFlight :: !Int,
    -- Channels
    ncMaxChannels :: !Int,
    ncDefaultChannelConfig :: !ChannelConfig,
    ncChannelConfigs :: ![ChannelConfig],
    -- Congestion
    ncCongestionThreshold :: !Double,
    ncCongestionGoodRttThresholdMs :: !Milliseconds,
    ncCongestionBadLossThreshold :: !Double,
    ncCongestionRecoveryTimeMs :: !Milliseconds,
    ncUseCwndCongestion :: !Bool,
    -- Disconnect
    ncDisconnectRetries :: !Int,
    ncDisconnectRetryTimeoutMs :: !Milliseconds,
    -- Security
    ncRateLimitPerSecond :: !Int,
    ncEncryptionKey :: !(Maybe EncryptionKey),
    ncEnableConnectionMigration :: !Bool,
    -- Replication
    ncDeltaBaselineTimeoutMs :: !Milliseconds,
    ncMaxBaselineSnapshots :: !Int,
    -- Simulation
    ncSimulation :: !(Maybe SimulationConfig)
  }
  deriving (Show)

-- | Sensible defaults for all parameters.
defaultNetworkConfig :: NetworkConfig
defaultNetworkConfig =
  NetworkConfig
    { ncProtocolId = 0x4E4E4554, -- "NNET"
      ncMaxClients = 64,
      ncMaxPending = 256,
      ncConnectionTimeoutMs = Milliseconds 10000.0,
      ncKeepaliveIntervalMs = Milliseconds 1000.0,
      ncConnectionRequestTimeoutMs = Milliseconds 5000.0,
      ncConnectionRequestMaxRetries = 5,
      ncMtu = 1200,
      ncSendRate = 60.0,
      ncMaxPacketRate = 120.0,
      ncFragmentThreshold = 1024,
      ncFragmentTimeoutMs = Milliseconds 5000.0,
      ncMaxFragments = 255,
      ncMaxReassemblyBufferSize = 1048576, -- 1 MB
      ncPacketBufferSize = 256,
      ncAckBufferSize = 256,
      ncMaxSequenceDistance = 32768,
      ncReliableRetryTimeMs = Milliseconds 100.0,
      ncMaxReliableRetries = 10,
      ncMaxInFlight = 256,
      ncMaxChannels = 8,
      ncDefaultChannelConfig = defaultChannelConfig,
      ncChannelConfigs = [],
      ncCongestionThreshold = 0.1,
      ncCongestionGoodRttThresholdMs = Milliseconds 250.0,
      ncCongestionBadLossThreshold = 0.1,
      ncCongestionRecoveryTimeMs = Milliseconds 10000.0,
      ncUseCwndCongestion = False,
      ncDisconnectRetries = 3,
      ncDisconnectRetryTimeoutMs = Milliseconds 500.0,
      ncRateLimitPerSecond = 10,
      ncEncryptionKey = Nothing,
      ncEnableConnectionMigration = True,
      ncDeltaBaselineTimeoutMs = Milliseconds 2000.0,
      ncMaxBaselineSnapshots = 32,
      ncSimulation = Nothing
    }

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

-- | Which config field failed validation.
data ConfigField
  = FieldMaxClients
  | FieldMaxPending
  | FieldMtu
  | FieldSendRate
  | FieldMaxPacketRate
  | FieldMaxChannels
  | FieldMaxSequenceDistance
  | FieldPacketBufferSize
  | FieldAckBufferSize
  | FieldMaxFragments
  | FieldMaxReassemblyBufferSize
  | FieldMaxInFlight
  | FieldMaxBaselineSnapshots
  | FieldRateLimitPerSecond
  | FieldConnectionTimeout
  | FieldKeepaliveInterval
  | FieldConnectionRequestTimeout
  | FieldConnectionRequestMaxRetries
  | FieldFragmentTimeout
  | FieldReliableRetryTime
  | FieldMaxReliableRetries
  | FieldCongestionThreshold
  | FieldCongestionGoodRttThreshold
  | FieldCongestionBadLossThreshold
  | FieldCongestionRecoveryTime
  | FieldDisconnectRetries
  | FieldDisconnectRetryTimeout
  | FieldDeltaBaselineTimeout
  | FieldSimPacketLoss
  | FieldSimDuplicateChance
  | FieldSimOutOfOrderChance
  | FieldCcMaxMessageSize
  | FieldCcMessageBufferSize
  | FieldCcOrderedBufferTimeout
  | FieldCcMaxOrderedBufferSize
  | FieldCcMaxReliableRetries
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | Configuration validation error.
data ConfigError
  = ConfigValueTooLow !ConfigField
  | ConfigValueTooHigh !ConfigField
  | ConfigValueNaN !ConfigField
  deriving (Eq, Show)

-- | Validate a 'NetworkConfig'. Returns all errors found.
validateConfig :: NetworkConfig -> [ConfigError]
validateConfig nc =
  concat
    [ positive FieldMaxClients (ncMaxClients nc),
      positive FieldMaxPending (ncMaxPending nc),
      ranged FieldMtu (ncMtu nc) 576 1500,
      positiveD FieldSendRate (ncSendRate nc),
      positiveD FieldMaxPacketRate (ncMaxPacketRate nc),
      positiveMs FieldConnectionTimeout (ncConnectionTimeoutMs nc),
      positiveMs FieldKeepaliveInterval (ncKeepaliveIntervalMs nc),
      positiveMs FieldConnectionRequestTimeout (ncConnectionRequestTimeoutMs nc),
      nonNeg FieldConnectionRequestMaxRetries (ncConnectionRequestMaxRetries nc),
      positiveMs FieldFragmentTimeout (ncFragmentTimeoutMs nc),
      positive FieldMaxFragments (ncMaxFragments nc),
      positive FieldMaxReassemblyBufferSize (ncMaxReassemblyBufferSize nc),
      positive FieldPacketBufferSize (ncPacketBufferSize nc),
      positive FieldAckBufferSize (ncAckBufferSize nc),
      positiveMs FieldReliableRetryTime (ncReliableRetryTimeMs nc),
      nonNeg FieldMaxReliableRetries (ncMaxReliableRetries nc),
      positive FieldMaxInFlight (ncMaxInFlight nc),
      ranged FieldMaxChannels (ncMaxChannels nc) 1 8,
      fraction FieldCongestionThreshold (ncCongestionThreshold nc),
      positiveMs FieldCongestionGoodRttThreshold (ncCongestionGoodRttThresholdMs nc),
      fraction FieldCongestionBadLossThreshold (ncCongestionBadLossThreshold nc),
      positiveMs FieldCongestionRecoveryTime (ncCongestionRecoveryTimeMs nc),
      nonNeg FieldDisconnectRetries (ncDisconnectRetries nc),
      positiveMs FieldDisconnectRetryTimeout (ncDisconnectRetryTimeoutMs nc),
      positive FieldRateLimitPerSecond (ncRateLimitPerSecond nc),
      positiveMs FieldDeltaBaselineTimeout (ncDeltaBaselineTimeoutMs nc),
      positive FieldMaxBaselineSnapshots (ncMaxBaselineSnapshots nc),
      if ncMaxSequenceDistance nc == 0
        then [ConfigValueTooLow FieldMaxSequenceDistance]
        else [],
      maybe [] validateSimConfig (ncSimulation nc),
      validateChannelConfig (ncDefaultChannelConfig nc),
      concatMap validateChannelConfig (ncChannelConfigs nc)
    ]

-- Internal validators

positive :: ConfigField -> Int -> [ConfigError]
positive f n
  | n > 0 = []
  | otherwise = [ConfigValueTooLow f]

nonNeg :: ConfigField -> Int -> [ConfigError]
nonNeg f n
  | n >= 0 = []
  | otherwise = [ConfigValueTooLow f]

ranged :: ConfigField -> Int -> Int -> Int -> [ConfigError]
ranged f n lo hi
  | n < lo = [ConfigValueTooLow f]
  | n > hi = [ConfigValueTooHigh f]
  | otherwise = []

positiveD :: ConfigField -> Double -> [ConfigError]
positiveD f d
  | isNaN d || isInfinite d = [ConfigValueNaN f]
  | d > 0.0 = []
  | otherwise = [ConfigValueTooLow f]

positiveMs :: ConfigField -> Milliseconds -> [ConfigError]
positiveMs f (Milliseconds ms) = positiveD f ms

fraction :: ConfigField -> Double -> [ConfigError]
fraction f d
  | isNaN d = [ConfigValueNaN f]
  | d < 0.0 = [ConfigValueTooLow f]
  | d > 1.0 = [ConfigValueTooHigh f]
  | otherwise = []

validateChannelConfig :: ChannelConfig -> [ConfigError]
validateChannelConfig cc =
  concat
    [ positive FieldCcMaxMessageSize (ccMaxMessageSize cc),
      positive FieldCcMessageBufferSize (ccMessageBufferSize cc),
      positiveMs FieldCcOrderedBufferTimeout (ccOrderedBufferTimeoutMs cc),
      positive FieldCcMaxOrderedBufferSize (ccMaxOrderedBufferSize cc),
      nonNeg FieldCcMaxReliableRetries (ccMaxReliableRetries cc)
    ]

validateSimConfig :: SimulationConfig -> [ConfigError]
validateSimConfig sc =
  concat
    [ fraction FieldSimPacketLoss (simPacketLoss sc),
      fraction FieldSimDuplicateChance (simDuplicateChance sc),
      fraction FieldSimOutOfOrderChance (simOutOfOrderChance sc)
    ]
