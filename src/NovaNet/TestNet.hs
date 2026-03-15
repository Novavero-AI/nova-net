{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : NovaNet.TestNet
-- Description : Pure deterministic network for testing
--
-- A simulated network that runs entirely in pure code (State monad).
-- Supports configurable latency, loss, jitter, duplicates, and
-- reordering.  Multi-peer world simulation for integration tests.
--
-- No real sockets — two NetPeer states in the same process with
-- manual packet routing between them.
module NovaNet.TestNet
  ( -- * Test network monad
    TestNet,
    runTestNet,

    -- * State
    TestNetConfig (..),
    TestNetState (..),
    InFlightPacket (..),
    initialTestNetState,
    defaultTestNetConfig,

    -- * Operations
    advanceTime,
    simulateLatency,
    simulateLoss,
    getPendingPackets,

    -- * Multi-peer world
    TestWorld (..),
    newTestWorld,
    runPeerInWorld,
    deliverPackets,
    worldAdvanceTime,
  )
where

import Control.Monad.State.Strict (MonadState, State, get, gets, modify', runState)
import Data.Bits (shiftL, shiftR, xor)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (partition)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import Network.Socket (SockAddr)
import NovaNet.Class
import NovaNet.Types (MonoTime (..), addNs)

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Nanoseconds per millisecond.
nsPerMs :: Word64
nsPerMs = 1000000

-- | Maximum extra delay for out-of-order simulation (50ms).
outOfOrderMaxDelayNs :: Word64
outOfOrderMaxDelayNs = 50000000

-- | Extra jitter for duplicate packet copies (10ms).
duplicateJitterNs :: Word64
duplicateJitterNs = 10000000

-- ---------------------------------------------------------------------------
-- RNG (xorshift64, deterministic)
-- ---------------------------------------------------------------------------

-- | Advance the xorshift64 RNG state. Returns (output, next).
xorshift64 :: Word64 -> (Word64, Word64)
xorshift64 s0 =
  let s1 = s0 `xor` (s0 `shiftL` 13)
      s2 = s1 `xor` (s1 `shiftR` 7)
      s3 = s2 `xor` (s2 `shiftL` 17)
   in (s3, s3)

-- | Convert a random Word64 to a Double in [0, 1).
randomDouble :: Word64 -> Double
randomDouble w = fromIntegral w / fromIntegral (maxBound :: Word64)
{-# INLINE randomDouble #-}

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | A packet in transit.
data InFlightPacket = InFlightPacket
  { ifpFrom :: !SockAddr,
    ifpTo :: !SockAddr,
    ifpData :: !ByteString,
    ifpDeliverAt :: !MonoTime
  }
  deriving (Show)

-- | Test network configuration.
data TestNetConfig = TestNetConfig
  { tncLatencyNs :: !Word64,
    tncLossRate :: !Double,
    tncJitterNs :: !Word64,
    tncDuplicateChance :: !Double,
    tncOutOfOrderChance :: !Double
  }
  deriving (Show)

-- | Default: no latency, no loss, no jitter.
defaultTestNetConfig :: TestNetConfig
defaultTestNetConfig =
  TestNetConfig
    { tncLatencyNs = 0,
      tncLossRate = 0.0,
      tncJitterNs = 0,
      tncDuplicateChance = 0.0,
      tncOutOfOrderChance = 0.0
    }

-- | State of the test network for one peer.
data TestNetState = TestNetState
  { tnsCurrentTime :: !MonoTime,
    tnsLocalAddr :: !SockAddr,
    tnsInFlight :: !(Seq InFlightPacket),
    tnsInbox :: !(Seq (ByteString, SockAddr)),
    tnsConfig :: !TestNetConfig,
    tnsRng :: !Word64,
    tnsClosed :: !Bool
  }
  deriving (Show)

-- | Create initial state for a peer.
initialTestNetState :: SockAddr -> TestNetState
initialTestNetState localAddr =
  TestNetState
    { tnsCurrentTime = MonoTime 0,
      tnsLocalAddr = localAddr,
      tnsInFlight = Seq.empty,
      tnsInbox = Seq.empty,
      tnsConfig = defaultTestNetConfig,
      tnsRng = 42,
      tnsClosed = False
    }

-- ---------------------------------------------------------------------------
-- TestNet monad
-- ---------------------------------------------------------------------------

-- | Pure deterministic network monad.
newtype TestNet a = TestNet (State TestNetState a)
  deriving (Functor, Applicative, Monad, MonadState TestNetState)

-- | Run a test network computation.
runTestNet :: TestNet a -> TestNetState -> (a, TestNetState)
runTestNet (TestNet m) = runState m

-- ---------------------------------------------------------------------------
-- MonadTime / MonadNetwork instances
-- ---------------------------------------------------------------------------

instance MonadTime TestNet where
  getMonoTime = gets tnsCurrentTime

instance MonadNetwork TestNet where
  netSend toAddr bytes = do
    st <- get
    if tnsClosed st
      then pure (Left NetSocketClosed)
      else do
        let cfg = tnsConfig st
            (r1, rng1) = xorshift64 (tnsRng st)
        if randomDouble r1 < tncLossRate cfg
          then do
            modify' $ \s -> s {tnsRng = rng1}
            pure (Right ())
          else do
            let (r2, rng2) = xorshift64 rng1
                jitter =
                  if tncJitterNs cfg == 0
                    then 0
                    else r2 `mod` (tncJitterNs cfg + 1)
                (r3, rng3) = xorshift64 rng2
                oooDelay =
                  if randomDouble r3 < tncOutOfOrderChance cfg
                    then r3 `mod` (outOfOrderMaxDelayNs + 1)
                    else 0
                deliverAt = addNs (tnsCurrentTime st) (tncLatencyNs cfg + jitter + oooDelay)
                pkt =
                  InFlightPacket
                    { ifpFrom = tnsLocalAddr st,
                      ifpTo = toAddr,
                      ifpData = bytes,
                      ifpDeliverAt = deliverAt
                    }
            -- Maybe duplicate
            let (r4, rng4) = xorshift64 rng3
            if randomDouble r4 < tncDuplicateChance cfg
              then do
                let (r5, rng5) = xorshift64 rng4
                    dupJitter = r5 `mod` (duplicateJitterNs + 1)
                    dupPkt = pkt {ifpDeliverAt = addNs deliverAt dupJitter}
                modify' $ \s ->
                  s
                    { tnsInFlight = tnsInFlight s |> pkt |> dupPkt,
                      tnsRng = rng5
                    }
              else modify' $ \s ->
                s
                  { tnsInFlight = tnsInFlight s |> pkt,
                    tnsRng = rng4
                  }
            pure (Right ())

  netRecv = do
    inbox <- gets tnsInbox
    case Seq.viewl inbox of
      Seq.EmptyL -> pure (Right Nothing)
      (bytes, from) Seq.:< rest -> do
        modify' $ \s -> s {tnsInbox = rest}
        pure (Right (Just (bytes, from)))

  netClose = modify' $ \s -> s {tnsClosed = True}

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

-- | Advance time and deliver packets that are ready.
advanceTime :: MonoTime -> TestNet ()
advanceTime newTime = do
  st <- get
  let (ready, stillInFlight) =
        Seq.partition (\p -> ifpDeliverAt p <= newTime) (tnsInFlight st)
      delivered =
        (\p -> (ifpData p, ifpFrom p))
          <$> Seq.filter (\p -> ifpTo p == tnsLocalAddr st) ready
  modify' $ \s ->
    s
      { tnsCurrentTime = newTime,
        tnsInFlight = stillInFlight,
        tnsInbox = tnsInbox s Seq.>< delivered
      }

-- | Set simulated one-way latency (milliseconds).
simulateLatency :: Word64 -> TestNet ()
simulateLatency ms = modify' $ \s ->
  s {tnsConfig = (tnsConfig s) {tncLatencyNs = ms * nsPerMs}}

-- | Set simulated packet loss rate (0.0 to 1.0).
simulateLoss :: Double -> TestNet ()
simulateLoss rate = modify' $ \s ->
  s {tnsConfig = (tnsConfig s) {tncLossRate = rate}}

-- | Get all packets currently in flight.
getPendingPackets :: TestNet [InFlightPacket]
getPendingPackets = gets (toList . tnsInFlight)

-- ---------------------------------------------------------------------------
-- Multi-peer world
-- ---------------------------------------------------------------------------

-- | A world containing multiple peers for integration testing.
data TestWorld = TestWorld
  { twPeers :: !(Map.Map SockAddr TestNetState),
    twGlobalTime :: !MonoTime
  }
  deriving (Show)

-- | Create a new empty test world.
newTestWorld :: TestWorld
newTestWorld =
  TestWorld
    { twPeers = Map.empty,
      twGlobalTime = MonoTime 0
    }

-- | Run a TestNet action for a specific peer. Auto-creates if missing.
runPeerInWorld :: SockAddr -> TestNet a -> TestWorld -> (a, TestWorld)
runPeerInWorld addr action world =
  let defaultState = (initialTestNetState addr) {tnsCurrentTime = twGlobalTime world}
      peerState = Map.findWithDefault defaultState addr (twPeers world)
      (result, updated) = runTestNet action peerState
   in (result, world {twPeers = Map.insert addr updated (twPeers world)})

-- | Deliver all ready packets between peers.
deliverPackets :: TestWorld -> TestWorld
deliverPackets world =
  let time = twGlobalTime world
      allPackets = concatMap (toList . tnsInFlight) (Map.elems (twPeers world))
      (ready, notReady) = partition (\p -> ifpDeliverAt p <= time) allPackets
      clearedPeers = Map.map (\ps -> ps {tnsInFlight = Seq.empty}) (twPeers world)
      peersWithPending = foldr putBackPending clearedPeers notReady
      peersWithDelivered = foldr (deliverOne time) peersWithPending ready
   in world {twPeers = peersWithDelivered}
  where
    putBackPending pkt =
      Map.adjust (\ps -> ps {tnsInFlight = tnsInFlight ps |> pkt}) (ifpFrom pkt)
    deliverOne globalTime pkt peers =
      let dest = ifpTo pkt
          entry = (ifpData pkt, ifpFrom pkt)
       in Map.alter
            ( \case
                Just ps -> Just ps {tnsInbox = tnsInbox ps |> entry}
                Nothing ->
                  let fresh = (initialTestNetState dest) {tnsCurrentTime = globalTime}
                   in Just fresh {tnsInbox = Seq.singleton entry}
            )
            dest
            peers

-- | Advance time for all peers and deliver ready packets.
worldAdvanceTime :: MonoTime -> TestWorld -> TestWorld
worldAdvanceTime newTime world =
  let updatedPeers = Map.map (\ps -> ps {tnsCurrentTime = newTime}) (twPeers world)
   in deliverPackets (world {twPeers = updatedPeers, twGlobalTime = newTime})
