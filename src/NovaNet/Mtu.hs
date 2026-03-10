-- |
-- Module      : NovaNet.Mtu
-- Description : Path MTU discovery via binary search
--
-- Pure state machine for discovering the maximum transmission unit
-- on a network path.  Sends probes of varying sizes and uses binary
-- search to converge on the largest working MTU within configured
-- bounds.  The Peer layer (Phase 4) drives the actual probe packets.
module NovaNet.Mtu
  ( -- * State
    MtuState (..),
    MtuDiscovery,
    newMtuDiscovery,

    -- * Probe lifecycle
    nextProbe,
    onProbeSuccess,
    onProbeTimeout,
    checkProbeTimeout,

    -- * Queries
    discoveredMtu,
    mtuIsComplete,
    mtuAttempts,
  )
where

import Data.Word (Word64)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Stop binary search when the range narrows to this many bytes.
convergenceThreshold :: Int
convergenceThreshold = 1

-- | Default probe timeout in nanoseconds (500 ms).
defaultProbeTimeoutNs :: Word64
defaultProbeTimeoutNs = 500 * 1000000

-- | Default maximum number of probes before declaring complete.
defaultMaxProbeAttempts :: Int
defaultMaxProbeAttempts = 10

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | MTU discovery phase.
data MtuState = MtuProbing | MtuComplete
  deriving (Eq, Ord, Show)

-- | MTU discovery state machine.  Binary search between low and high
-- bounds, converging on the largest size that the path supports.
data MtuDiscovery = MtuDiscovery
  { mdLowBound :: !Int,
    mdHighBound :: !Int,
    mdCurrentProbe :: !Int,
    mdDiscoveredMtu :: !Int,
    mdState :: !MtuState,
    mdProbeTimeoutNs :: !Word64,
    mdLastProbeTime :: !(Maybe MonoTime),
    mdAttempts :: !Int,
    mdMaxAttempts :: !Int
  }

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create an MTU discovery state with the given bounds.
-- The initial discovered MTU is the low bound (safe default).
-- Probes start at the midpoint.
newMtuDiscovery :: Int -> Int -> MtuDiscovery
newMtuDiscovery low high =
  MtuDiscovery
    { mdLowBound = low,
      mdHighBound = high,
      mdCurrentProbe = (low + high) `div` 2,
      mdDiscoveredMtu = low,
      mdState = MtuProbing,
      mdProbeTimeoutNs = defaultProbeTimeoutNs,
      mdLastProbeTime = Nothing,
      mdAttempts = 0,
      mdMaxAttempts = defaultMaxProbeAttempts
    }

-- ---------------------------------------------------------------------------
-- Probe lifecycle
-- ---------------------------------------------------------------------------

-- | Get the next probe size to send.  Returns 'Nothing' when discovery
-- is complete (converged, max attempts reached, or already done).
-- Records the probe time and increments the attempt counter.
nextProbe :: MonoTime -> MtuDiscovery -> (Maybe Int, MtuDiscovery)
nextProbe now md
  | mdState md == MtuComplete = (Nothing, md)
  | mdAttempts md >= mdMaxAttempts md =
      (Nothing, md {mdState = MtuComplete})
  | mdHighBound md - mdLowBound md <= convergenceThreshold =
      (Nothing, md {mdState = MtuComplete})
  | not (probeReady now md) = (Nothing, md)
  | otherwise =
      let probe = (mdLowBound md + mdHighBound md) `div` 2
          updated =
            md
              { mdCurrentProbe = probe,
                mdLastProbeTime = Just now,
                mdAttempts = mdAttempts md + 1
              }
       in (Just probe, updated)

-- | A probe of the given size was acknowledged — this size works.
-- Raises the lower bound and updates the discovered MTU.
onProbeSuccess :: Int -> MtuDiscovery -> MtuDiscovery
onProbeSuccess size md =
  md
    { mdLowBound = max (mdLowBound md) size,
      mdDiscoveredMtu = max (mdDiscoveredMtu md) size
    }

-- | The current probe timed out — the probed size is too large.
-- Lowers the upper bound.
onProbeTimeout :: MtuDiscovery -> MtuDiscovery
onProbeTimeout md =
  md {mdHighBound = mdCurrentProbe md}

-- | Check if the current probe has timed out.  If so, applies
-- 'onProbeTimeout' automatically.  Call once per tick.
checkProbeTimeout :: MonoTime -> MtuDiscovery -> MtuDiscovery
checkProbeTimeout now md =
  case mdLastProbeTime md of
    Nothing -> md
    Just lastTime
      | diffNs lastTime now >= mdProbeTimeoutNs md -> onProbeTimeout md
      | otherwise -> md

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | The best confirmed MTU so far.
discoveredMtu :: MtuDiscovery -> Int
discoveredMtu = mdDiscoveredMtu
{-# INLINE discoveredMtu #-}

-- | Has MTU discovery finished?
mtuIsComplete :: MtuDiscovery -> Bool
mtuIsComplete md = mdState md == MtuComplete
{-# INLINE mtuIsComplete #-}

-- | Number of probes sent so far.
mtuAttempts :: MtuDiscovery -> Int
mtuAttempts = mdAttempts
{-# INLINE mtuAttempts #-}

-- ---------------------------------------------------------------------------
-- Internal
-- ---------------------------------------------------------------------------

probeReady :: MonoTime -> MtuDiscovery -> Bool
probeReady now md =
  case mdLastProbeTime md of
    Nothing -> True
    Just lastTime -> diffNs lastTime now >= mdProbeTimeoutNs md
{-# INLINE probeReady #-}
