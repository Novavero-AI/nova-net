-- |
-- Module      : NovaNet.Simulator
-- Description : Network condition simulator
--
-- Simulates packet loss, latency, jitter, duplicates, reordering,
-- and bandwidth limiting.  Used for testing under realistic network
-- conditions without real sockets.
module NovaNet.Simulator
  ( -- * Simulator
    NetworkSimulator,
    newNetworkSimulator,
    simulatorProcessSend,
    simulatorReceiveReady,
    simulatorPendingCount,
    simulatorConfig,

    -- * Delayed packet
    DelayedPacket (..),
  )
where

import Data.Bits (shiftL, shiftR, xor)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Foldable (toList)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import NovaNet.Config (SimulationConfig (..))
import NovaNet.Types (Milliseconds (..), MonoTime (..), addNs, diffNs)

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Maximum extra delay for out-of-order packets (ms).
outOfOrderMaxDelayMs :: Double
outOfOrderMaxDelayMs = 50.0

-- | Packets below this total delay (ms) are delivered immediately.
immediateDeliveryThresholdMs :: Double
immediateDeliveryThresholdMs = 1.0

-- | Extra jitter for duplicate copies (ms).
duplicateJitterMs :: Double
duplicateJitterMs = 20.0

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | A packet delayed for later delivery.
data DelayedPacket = DelayedPacket
  { dpData :: !ByteString,
    dpAddr :: !Word64,
    dpDeliverAt :: !MonoTime
  }
  deriving (Show)

-- | Network condition simulator.
data NetworkSimulator = NetworkSimulator
  { nsConfig :: !SimulationConfig,
    nsDelayedPackets :: !(Seq DelayedPacket),
    nsTokenBucketTokens :: !Double,
    nsLastTokenRefill :: !MonoTime,
    nsRngState :: !Word64
  }

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a new network simulator.
newNetworkSimulator :: SimulationConfig -> MonoTime -> NetworkSimulator
newNetworkSimulator config now =
  NetworkSimulator
    { nsConfig = config,
      nsDelayedPackets = Seq.empty,
      nsTokenBucketTokens = 0.0,
      nsLastTokenRefill = now,
      nsRngState = unMonoTime now
    }

-- ---------------------------------------------------------------------------
-- Processing
-- ---------------------------------------------------------------------------

-- | Process an outgoing packet through the simulator.
-- Returns (immediate deliveries, updated simulator).
simulatorProcessSend ::
  ByteString ->
  Word64 ->
  MonoTime ->
  NetworkSimulator ->
  ([(ByteString, Word64)], NetworkSimulator)
simulatorProcessSend dat addr now sim0 =
  let (r1, sim1) = nextRng sim0
      config = nsConfig sim1
   in if checkLoss config r1
        then ([], sim1)
        else
          let (overBw, sim2) = checkBandwidth (BS.length dat) now sim1
           in if overBw
                then ([], sim2)
                else
                  let (r2, sim3) = nextRng sim2
                      (r3, sim4) = nextRng sim3
                      (r4, sim5) = nextRng sim4
                      totalDelayMs = calculateDelay config r2 r3 r4
                      deliverAt = addNs now (round (totalDelayMs * 1e6))
                      (immediate, sim6) = scheduleOrDeliver dat addr deliverAt totalDelayMs sim5
                      sim7 = scheduleDuplicate dat addr now totalDelayMs config sim6
                   in (immediate, sim7)

-- | Retrieve packets ready for delivery.
simulatorReceiveReady :: MonoTime -> NetworkSimulator -> ([(ByteString, Word64)], NetworkSimulator)
simulatorReceiveReady now sim =
  let (ready, notReady) = Seq.partition (\pkt -> dpDeliverAt pkt <= now) (nsDelayedPackets sim)
      results = map (\pkt -> (dpData pkt, dpAddr pkt)) (toList ready)
   in (results, sim {nsDelayedPackets = notReady})

-- | Number of pending delayed packets.
simulatorPendingCount :: NetworkSimulator -> Int
simulatorPendingCount = Seq.length . nsDelayedPackets
{-# INLINE simulatorPendingCount #-}

-- | Get the simulation configuration.
simulatorConfig :: NetworkSimulator -> SimulationConfig
simulatorConfig = nsConfig
{-# INLINE simulatorConfig #-}

-- ---------------------------------------------------------------------------
-- Internal
-- ---------------------------------------------------------------------------

-- | Check if a packet should be dropped due to loss.
checkLoss :: SimulationConfig -> Word64 -> Bool
checkLoss config rng =
  let threshold = simPacketLoss config
   in threshold > 0.0 && randomDouble rng < threshold

-- | Check bandwidth limit, consuming tokens if available.
checkBandwidth :: Int -> MonoTime -> NetworkSimulator -> (Bool, NetworkSimulator)
checkBandwidth packetSize now sim
  | simBandwidthLimitBytesPerSec (nsConfig sim) <= 0 = (False, sim)
  | otherwise =
      let sim2 = refillTokens now sim
          needed = fromIntegral packetSize
       in if nsTokenBucketTokens sim2 < needed
            then (True, sim2)
            else (False, sim2 {nsTokenBucketTokens = nsTokenBucketTokens sim2 - needed})

-- | Calculate total delay (ms) including latency, jitter, reordering.
calculateDelay :: SimulationConfig -> Word64 -> Word64 -> Word64 -> Double
calculateDelay config rJitter rOoOChance rOoODelay =
  let baseLatency = unMilliseconds (simLatencyMs config)
      jitterMax = unMilliseconds (simJitterMs config)
      jitter =
        if jitterMax > 0.0
          then randomDouble rJitter * jitterMax
          else 0.0
      extraDelay =
        if simOutOfOrderChance config > 0.0 && randomDouble rOoOChance < simOutOfOrderChance config
          then randomDouble rOoODelay * outOfOrderMaxDelayMs
          else 0.0
   in baseLatency + jitter + extraDelay

-- | Deliver immediately or schedule for later.
scheduleOrDeliver :: ByteString -> Word64 -> MonoTime -> Double -> NetworkSimulator -> ([(ByteString, Word64)], NetworkSimulator)
scheduleOrDeliver dat addr deliverAt totalDelayMs sim
  | totalDelayMs < immediateDeliveryThresholdMs = ([(dat, addr)], sim)
  | otherwise =
      let delayed = DelayedPacket {dpData = dat, dpAddr = addr, dpDeliverAt = deliverAt}
       in ([], sim {nsDelayedPackets = nsDelayedPackets sim |> delayed})

-- | Maybe schedule a duplicate packet.
scheduleDuplicate :: ByteString -> Word64 -> MonoTime -> Double -> SimulationConfig -> NetworkSimulator -> NetworkSimulator
scheduleDuplicate dat addr now baseDelayMs config sim =
  let (r, sim2) = nextRng sim
      dupChance = simDuplicateChance config
   in if dupChance > 0.0 && randomDouble r < dupChance
        then
          let dupDelayMs = baseDelayMs + randomDouble r * duplicateJitterMs
              dupDeliverAt = addNs now (round (dupDelayMs * 1e6))
              dupPkt = DelayedPacket {dpData = dat, dpAddr = addr, dpDeliverAt = dupDeliverAt}
           in sim2 {nsDelayedPackets = nsDelayedPackets sim2 |> dupPkt}
        else sim2

-- | Refill token bucket based on elapsed time.
refillTokens :: MonoTime -> NetworkSimulator -> NetworkSimulator
refillTokens now sim =
  let elapsedNs = diffNs (nsLastTokenRefill sim) now
      elapsedSecs = fromIntegral elapsedNs / 1e9 :: Double
      refillRate = fromIntegral (simBandwidthLimitBytesPerSec (nsConfig sim))
      newTokens = nsTokenBucketTokens sim + elapsedSecs * refillRate
      cappedTokens = min newTokens refillRate
   in sim {nsTokenBucketTokens = cappedTokens, nsLastTokenRefill = now}

-- | Advance RNG and return (output, updated sim).
nextRng :: NetworkSimulator -> (Word64, NetworkSimulator)
nextRng sim =
  let s0 = nsRngState sim
      s1 = s0 `xor` (s0 `shiftL` 13)
      s2 = s1 `xor` (s1 `shiftR` 7)
      s3 = s2 `xor` (s2 `shiftL` 17)
   in (s3, sim {nsRngState = s3})

-- | Convert Word64 to Double in [0, 1).
randomDouble :: Word64 -> Double
randomDouble w = fromIntegral w / fromIntegral (maxBound :: Word64)
{-# INLINE randomDouble #-}
