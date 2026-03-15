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

    -- * Protocol constants
    minMtu,
    maxMtu,
    seqHalfRange,
    cookieSecretSize,
    migrationCooldownNs,
    maxUdpPacketSize,
  )
where

import Data.Bits ((.&.))
import Data.Word (Word16, Word32, Word64, Word8)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Channel configuration
-- ---------------------------------------------------------------------------

-- | Per-channel configuration.
data ChannelConfig = ChannelConfig
  { ccDeliveryMode :: !DeliveryMode,
    ccMaxMessageSize :: !Int,
    ccMessageBufferSize :: !Int,
    ccFullBufferPolicy :: !FullBufferPolicy,
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
      ccMaxMessageSize = defaultCcMaxMessageSize,
      ccMessageBufferSize = defaultCcMessageBufferSize,
      ccFullBufferPolicy = DropOnFull,
      ccOrderedBufferTimeoutMs = defaultCcOrderedBufferTimeoutMs,
      ccMaxOrderedBufferSize = defaultCcMaxOrderedBufferSize,
      ccMaxReliableRetries = defaultCcMaxReliableRetries,
      ccPriority = defaultCcPriority
    }

-- Channel config defaults (internal)

defaultCcMaxMessageSize :: Int
defaultCcMaxMessageSize = 1024

defaultCcMessageBufferSize :: Int
defaultCcMessageBufferSize = 256

defaultCcOrderedBufferTimeoutMs :: Milliseconds
defaultCcOrderedBufferTimeoutMs = Milliseconds 5000.0

defaultCcMaxOrderedBufferSize :: Int
defaultCcMaxOrderedBufferSize = 64

defaultCcMaxReliableRetries :: Int
defaultCcMaxReliableRetries = 10

defaultCcPriority :: Word8
defaultCcPriority = 128

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
    ncCongestionMode :: !CongestionMode,
    -- Disconnect
    ncDisconnectRetries :: !Int,
    ncDisconnectRetryTimeoutMs :: !Milliseconds,
    -- Security
    ncRateLimitPerSecond :: !Int,
    ncEncryptionKey :: !(Maybe EncryptionKey),
    ncMigrationPolicy :: !MigrationPolicy,
    -- Replication
    ncDeltaBaselineTimeoutMs :: !Milliseconds,
    ncMaxBaselineSnapshots :: !Int,
    -- Simulation
    ncSimulation :: !(Maybe SimulationConfig)
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Protocol constants
-- ---------------------------------------------------------------------------

-- | Minimum MTU (RFC 791 minimum IPv4 datagram).
minMtu :: Int
minMtu = 576

-- | Maximum MTU (UDP maximum payload size).
maxMtu :: Int
maxMtu = 65535

-- | Half of the 16-bit sequence space — maximum safe comparison distance.
seqHalfRange :: Word16
seqHalfRange = 32768

-- | Size of the SipHash cookie secret in bytes.
cookieSecretSize :: Int
cookieSecretSize = 16

-- | Migration cooldown in nanoseconds (5 seconds).
migrationCooldownNs :: Word64
migrationCooldownNs = 5000000000

-- | Maximum UDP datagram size.
maxUdpPacketSize :: Int
maxUdpPacketSize = 65536

-- ---------------------------------------------------------------------------
-- Network config defaults (internal)
-- ---------------------------------------------------------------------------

defaultProtocolId :: Word32
defaultProtocolId = 0x4E4E4554 -- "NNET"

defaultMaxClients :: Int
defaultMaxClients = 64

defaultMaxPending :: Int
defaultMaxPending = 256

defaultConnectionTimeoutMs :: Milliseconds
defaultConnectionTimeoutMs = Milliseconds 10000.0

defaultKeepaliveIntervalMs :: Milliseconds
defaultKeepaliveIntervalMs = Milliseconds 1000.0

defaultConnectionRequestTimeoutMs :: Milliseconds
defaultConnectionRequestTimeoutMs = Milliseconds 5000.0

defaultConnectionRequestMaxRetries :: Int
defaultConnectionRequestMaxRetries = 5

defaultMtu :: Int
defaultMtu = 1200

defaultSendRate :: Double
defaultSendRate = 60.0

defaultMaxPacketRate :: Double
defaultMaxPacketRate = 120.0

defaultFragmentThreshold :: Int
defaultFragmentThreshold = 1024

defaultFragmentTimeoutMs :: Milliseconds
defaultFragmentTimeoutMs = Milliseconds 5000.0

defaultMaxFragments :: Int
defaultMaxFragments = 255

defaultMaxReassemblyBufferSize :: Int
defaultMaxReassemblyBufferSize = 1024 * 1024 -- 1 MiB

defaultPacketBufferSize :: Int
defaultPacketBufferSize = 256

defaultAckBufferSize :: Int
defaultAckBufferSize = 256

defaultMaxSequenceDistance :: Word16
defaultMaxSequenceDistance = 32768

defaultReliableRetryTimeMs :: Milliseconds
defaultReliableRetryTimeMs = Milliseconds 100.0

defaultMaxReliableRetries :: Int
defaultMaxReliableRetries = 10

defaultMaxInFlight :: Int
defaultMaxInFlight = 256

defaultMaxChannels :: Int
defaultMaxChannels = 8

defaultCongestionThreshold :: Double
defaultCongestionThreshold = 0.1

defaultCongestionGoodRttThresholdMs :: Milliseconds
defaultCongestionGoodRttThresholdMs = Milliseconds 250.0

defaultCongestionBadLossThreshold :: Double
defaultCongestionBadLossThreshold = 0.1

defaultCongestionRecoveryTimeMs :: Milliseconds
defaultCongestionRecoveryTimeMs = Milliseconds 10000.0

defaultDisconnectRetries :: Int
defaultDisconnectRetries = 3

defaultDisconnectRetryTimeoutMs :: Milliseconds
defaultDisconnectRetryTimeoutMs = Milliseconds 500.0

defaultRateLimitPerSecond :: Int
defaultRateLimitPerSecond = 10

defaultDeltaBaselineTimeoutMs :: Milliseconds
defaultDeltaBaselineTimeoutMs = Milliseconds 2000.0

defaultMaxBaselineSnapshots :: Int
defaultMaxBaselineSnapshots = 32

-- ---------------------------------------------------------------------------

-- | Sensible defaults for all parameters.
defaultNetworkConfig :: NetworkConfig
defaultNetworkConfig =
  NetworkConfig
    { ncProtocolId = defaultProtocolId,
      ncMaxClients = defaultMaxClients,
      ncMaxPending = defaultMaxPending,
      ncConnectionTimeoutMs = defaultConnectionTimeoutMs,
      ncKeepaliveIntervalMs = defaultKeepaliveIntervalMs,
      ncConnectionRequestTimeoutMs = defaultConnectionRequestTimeoutMs,
      ncConnectionRequestMaxRetries = defaultConnectionRequestMaxRetries,
      ncMtu = defaultMtu,
      ncSendRate = defaultSendRate,
      ncMaxPacketRate = defaultMaxPacketRate,
      ncFragmentThreshold = defaultFragmentThreshold,
      ncFragmentTimeoutMs = defaultFragmentTimeoutMs,
      ncMaxFragments = defaultMaxFragments,
      ncMaxReassemblyBufferSize = defaultMaxReassemblyBufferSize,
      ncPacketBufferSize = defaultPacketBufferSize,
      ncAckBufferSize = defaultAckBufferSize,
      ncMaxSequenceDistance = defaultMaxSequenceDistance,
      ncReliableRetryTimeMs = defaultReliableRetryTimeMs,
      ncMaxReliableRetries = defaultMaxReliableRetries,
      ncMaxInFlight = defaultMaxInFlight,
      ncMaxChannels = defaultMaxChannels,
      ncDefaultChannelConfig = defaultChannelConfig,
      ncChannelConfigs = [],
      ncCongestionThreshold = defaultCongestionThreshold,
      ncCongestionGoodRttThresholdMs = defaultCongestionGoodRttThresholdMs,
      ncCongestionBadLossThreshold = defaultCongestionBadLossThreshold,
      ncCongestionRecoveryTimeMs = defaultCongestionRecoveryTimeMs,
      ncCongestionMode = BinaryAIMD,
      ncDisconnectRetries = defaultDisconnectRetries,
      ncDisconnectRetryTimeoutMs = defaultDisconnectRetryTimeoutMs,
      ncRateLimitPerSecond = defaultRateLimitPerSecond,
      ncEncryptionKey = Nothing,
      ncMigrationPolicy = MigrationDisabled,
      ncDeltaBaselineTimeoutMs = defaultDeltaBaselineTimeoutMs,
      ncMaxBaselineSnapshots = defaultMaxBaselineSnapshots,
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
  | FieldFragmentThreshold
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
  | FieldSimLatency
  | FieldSimJitter
  | FieldSimOutOfOrderMaxDelay
  | FieldSimBandwidthLimit
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
  | ConfigNotPowerOfTwo !ConfigField
  | ConfigKeepaliveExceedsTimeout
  | ConfigFragmentExceedsMtu
  | ConfigMigrationRequiresEncryption
  | ConfigTooManyChannelConfigs
  deriving (Eq, Show)

-- | Validate a 'NetworkConfig'. Returns all errors found.
validateConfig :: NetworkConfig -> [ConfigError]
validateConfig nc =
  concat
    [ -- Single-field validations
      positive FieldMaxClients (ncMaxClients nc),
      positive FieldMaxPending (ncMaxPending nc),
      ranged FieldMtu (ncMtu nc) minMtu maxMtu,
      positiveD FieldSendRate (ncSendRate nc),
      positiveD FieldMaxPacketRate (ncMaxPacketRate nc),
      positiveMs FieldConnectionTimeout (ncConnectionTimeoutMs nc),
      positiveMs FieldKeepaliveInterval (ncKeepaliveIntervalMs nc),
      positiveMs FieldConnectionRequestTimeout (ncConnectionRequestTimeoutMs nc),
      nonNeg FieldConnectionRequestMaxRetries (ncConnectionRequestMaxRetries nc),
      positive FieldFragmentThreshold (ncFragmentThreshold nc),
      positiveMs FieldFragmentTimeout (ncFragmentTimeoutMs nc),
      positive FieldMaxFragments (ncMaxFragments nc),
      positive FieldMaxReassemblyBufferSize (ncMaxReassemblyBufferSize nc),
      powerOfTwo FieldPacketBufferSize (ncPacketBufferSize nc),
      powerOfTwo FieldAckBufferSize (ncAckBufferSize nc),
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
      [ConfigValueTooLow FieldMaxSequenceDistance | ncMaxSequenceDistance nc == 0],
      [ConfigValueTooHigh FieldMaxSequenceDistance | ncMaxSequenceDistance nc > seqHalfRange],
      -- Cross-field validations
      [ ConfigKeepaliveExceedsTimeout
      | unMilliseconds (ncKeepaliveIntervalMs nc)
          >= unMilliseconds (ncConnectionTimeoutMs nc)
      ],
      [ ConfigFragmentExceedsMtu
      | ncFragmentThreshold nc > ncMtu nc
      ],
      [ ConfigMigrationRequiresEncryption
      | ncMigrationPolicy nc == MigrationEnabled,
        Nothing <- [ncEncryptionKey nc]
      ],
      [ ConfigTooManyChannelConfigs
      | length (ncChannelConfigs nc) > ncMaxChannels nc
      ],
      -- Nested validations
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

nonNegMs :: ConfigField -> Milliseconds -> [ConfigError]
nonNegMs f (Milliseconds ms)
  | isNaN ms || isInfinite ms = [ConfigValueNaN f]
  | ms >= 0.0 = []
  | otherwise = [ConfigValueTooLow f]

fraction :: ConfigField -> Double -> [ConfigError]
fraction f d
  | isNaN d = [ConfigValueNaN f]
  | d < 0.0 = [ConfigValueTooLow f]
  | d > 1.0 = [ConfigValueTooHigh f]
  | otherwise = []

powerOfTwo :: ConfigField -> Int -> [ConfigError]
powerOfTwo f n
  | n > 0 && (n .&. (n - 1)) == 0 = []
  | otherwise = [ConfigNotPowerOfTwo f]

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
      fraction FieldSimOutOfOrderChance (simOutOfOrderChance sc),
      nonNegMs FieldSimLatency (simLatencyMs sc),
      nonNegMs FieldSimJitter (simJitterMs sc),
      nonNegMs FieldSimOutOfOrderMaxDelay (simOutOfOrderMaxDelayMs sc),
      nonNeg FieldSimBandwidthLimit (simBandwidthLimitBytesPerSec sc)
    ]
