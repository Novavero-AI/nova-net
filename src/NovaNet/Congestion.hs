-- |
-- Module      : NovaNet.Congestion
-- Description : Congestion control orchestration
--
-- Thin Haskell layer over the C AIMD and CWND controllers.
-- The Connection layer calls 'congestionTick' each frame and
-- 'congestionOnAck'/'congestionOnLoss' when ACK results arrive.
module NovaNet.Congestion
  ( -- * Controller
    CongestionController,
    CongestionLayer (..),
    newCongestionController,

    -- * Per-tick update
    congestionTick,

    -- * ACK/loss events
    congestionOnAck,
    congestionOnLoss,

    -- * Send gating
    congestionCanSend,
    congestionOnSend,

    -- * Queries
    congestionRate,
    congestionPacingNs,

    -- * Idle detection
    congestionCheckIdle,
  )
where

import Data.Int (Int32, Int64)
import Data.Word (Word16, Word32)
import NovaNet.FFI.Congestion
import NovaNet.Types (CongestionMode (..), MonoTime (..))

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | Which congestion control layer is active.
data CongestionLayer
  = LayerAimd
  | LayerCwnd
  deriving (Eq, Show)

-- | Congestion controller owning the C state.
data CongestionController
  = CCAimd !AimdController
  | CCCwnd !CwndController

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a congestion controller based on the configured mode.
newCongestionController ::
  CongestionMode ->
  Double ->
  Double ->
  Int64 ->
  Word32 ->
  IO CongestionController
newCongestionController mode baseRate lossThresh rttThreshNs mss =
  case mode of
    BinaryAIMD -> CCAimd <$> newAimdController baseRate lossThresh rttThreshNs
    CwndTcpLike -> CCCwnd <$> newCwndController mss

-- ---------------------------------------------------------------------------
-- Per-tick update
-- ---------------------------------------------------------------------------

-- | Per-tick update.  For AIMD: transitions modes, adjusts rate, refills
-- budget.  For CWND: checks idle restart.
congestionTick ::
  CongestionController ->
  Double ->
  Double ->
  Int64 ->
  MonoTime ->
  IO ()
congestionTick (CCAimd aimd) dtSec lossFrac srttNs (MonoTime nowNs) =
  aimdTick aimd dtSec lossFrac srttNs (fromIntegral nowNs)
congestionTick (CCCwnd cwnd) _ _ srttNs (MonoTime nowNs) = do
  cwndSetSrtt cwnd srttNs
  cwndCheckIdle cwnd (fromIntegral nowNs) srttNs

-- ---------------------------------------------------------------------------
-- ACK/loss events
-- ---------------------------------------------------------------------------

-- | Notify congestion controller of acked bytes.
congestionOnAck ::
  CongestionController ->
  Int32 ->
  Word16 ->
  IO ()
congestionOnAck (CCAimd _) _ _ = pure ()
congestionOnAck (CCCwnd cwnd) ackedBytes ackedSeq = do
  cwndOnAck cwnd ackedBytes
  cwndOnAckSeq cwnd ackedSeq ackedBytes

-- | Notify congestion controller of a loss event.
congestionOnLoss ::
  CongestionController ->
  Word16 ->
  MonoTime ->
  IO ()
congestionOnLoss (CCAimd _) _ _ = pure ()
congestionOnLoss (CCCwnd cwnd) lossSeq (MonoTime nowNs) =
  cwndOnLoss cwnd lossSeq (fromIntegral nowNs)

-- ---------------------------------------------------------------------------
-- Send gating
-- ---------------------------------------------------------------------------

-- | Can we send a packet of this size?
congestionCanSend :: CongestionController -> Int32 -> IO Bool
congestionCanSend (CCAimd aimd) _ = aimdCanSend aimd
congestionCanSend (CCCwnd cwnd) pktSize = cwndCanSend cwnd pktSize

-- | Record a sent packet.
congestionOnSend :: CongestionController -> Int32 -> MonoTime -> IO ()
congestionOnSend (CCAimd aimd) _ _ = aimdDeduct aimd
congestionOnSend (CCCwnd cwnd) pktSize (MonoTime nowNs) =
  cwndOnSend cwnd pktSize (fromIntegral nowNs)

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Current send rate (AIMD: packets/sec, CWND: 0 — use pacing instead).
congestionRate :: CongestionController -> IO Double
congestionRate (CCAimd aimd) = aimdRate aimd
congestionRate (CCCwnd _) = pure 0.0

-- | Pacing interval in nanoseconds (CWND only, AIMD returns 0).
congestionPacingNs :: CongestionController -> IO Int64
congestionPacingNs (CCAimd _) = pure 0
congestionPacingNs (CCCwnd cwnd) = cwndPacingNs cwnd

-- ---------------------------------------------------------------------------
-- Idle detection
-- ---------------------------------------------------------------------------

-- | Check for idle restart (CWND: 2 RTOs idle -> slow start).
congestionCheckIdle :: CongestionController -> MonoTime -> Int64 -> IO ()
congestionCheckIdle (CCAimd _) _ _ = pure ()
congestionCheckIdle (CCCwnd cwnd) (MonoTime nowNs) rtoNs =
  cwndCheckIdle cwnd (fromIntegral nowNs) rtoNs
