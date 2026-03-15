{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : NovaNet.Replication.Delta
-- Description : Delta compression for bandwidth-efficient state replication
--
-- 'DeltaTracker' manages per-sequence snapshots for delta encoding
-- against acknowledged baselines (sender side).  'BaselineManager'
-- provides a ring buffer of confirmed snapshots per connection
-- (receiver side).
--
-- The 'NetworkDelta' typeclass defines how to compute and apply
-- deltas for a given state type.  Serialization is left to the
-- caller — this module handles only the state tracking.
module NovaNet.Replication.Delta
  ( -- * Types
    BaselineSeq,
    noBaseline,

    -- * NetworkDelta typeclass
    NetworkDelta (..),

    -- * Delta tracker (sender side)
    DeltaTracker,
    newDeltaTracker,
    deltaEncode,
    deltaOnAck,
    deltaReset,
    deltaConfirmedSeq,

    -- * Baseline manager (receiver side)
    BaselineManager,
    newBaselineManager,
    pushBaseline,
    getBaseline,
    baselineCleanup,
    baselineReset,
    baselineCount,
    baselineIsEmpty,
  )
where

import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Word (Word16, Word64)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | Sequence number identifying a baseline snapshot on the wire.
type BaselineSeq = Word16

-- | Sentinel: no baseline available, full state required.
noBaseline :: BaselineSeq
noBaseline = maxBound

-- ---------------------------------------------------------------------------
-- NetworkDelta typeclass
-- ---------------------------------------------------------------------------

-- | Typeclass for delta-compressed network types.
--
-- The associated 'Delta' type contains only the changed fields.
-- Implement 'diff' to compute a delta from baseline to current,
-- and 'apply' to reconstruct state from a baseline and delta.
class NetworkDelta a where
  type Delta a
  diff :: a -> a -> Delta a
  apply :: a -> Delta a -> a

-- ---------------------------------------------------------------------------
-- Delta tracker (sender side)
-- ---------------------------------------------------------------------------

-- | Tracks pending snapshots and encodes deltas against confirmed baselines.
data DeltaTracker a = DeltaTracker
  { dtPending :: !(Seq (BaselineSeq, a)),
    dtConfirmed :: !(Maybe (BaselineSeq, a)),
    dtMaxPending :: !Int
  }

-- | Create a new delta tracker.
newDeltaTracker :: Int -> DeltaTracker a
newDeltaTracker maxPending =
  DeltaTracker
    { dtPending = Seq.empty,
      dtConfirmed = Nothing,
      dtMaxPending = maxPending
    }

-- | Encode a snapshot as a delta against the confirmed baseline.
--
-- Returns the delta (or full state if no baseline), and updates
-- the tracker with the pending snapshot.
--
-- The caller is responsible for serialization — this function returns
-- the baseline sequence and either the delta or the full state.
deltaEncode ::
  (NetworkDelta a) =>
  BaselineSeq ->
  a ->
  DeltaTracker a ->
  (BaselineSeq, Either a (Delta a), DeltaTracker a)
deltaEncode seqNum current tracker =
  let (baseSeq, result) = case dtConfirmed tracker of
        Just (confirmedSeq, baseline) ->
          (confirmedSeq, Right (diff current baseline))
        Nothing ->
          (noBaseline, Left current)
      pending = dtPending tracker
      updated =
        if Seq.length pending >= dtMaxPending tracker
          then Seq.drop 1 pending |> (seqNum, current)
          else pending |> (seqNum, current)
   in (baseSeq, result, tracker {dtPending = updated})

-- | Called when a sequence is ACK'd.
--
-- Promotes the matching snapshot to confirmed baseline and discards
-- older pending entries.
deltaOnAck :: BaselineSeq -> DeltaTracker a -> DeltaTracker a
deltaOnAck seqNum tracker =
  case Seq.findIndexL (\(s, _) -> s == seqNum) (dtPending tracker) of
    Nothing -> tracker
    Just idx ->
      case Seq.lookup idx (dtPending tracker) of
        Nothing -> tracker
        Just (ackSeq, snapshot) ->
          let remaining = Seq.drop (idx + 1) (dtPending tracker)
           in tracker
                { dtPending = remaining,
                  dtConfirmed = Just (ackSeq, snapshot)
                }

-- | Reset tracker state (e.g. on reconnect).
deltaReset :: DeltaTracker a -> DeltaTracker a
deltaReset tracker =
  tracker
    { dtPending = Seq.empty,
      dtConfirmed = Nothing
    }

-- | The confirmed baseline sequence, if any.
deltaConfirmedSeq :: DeltaTracker a -> Maybe BaselineSeq
deltaConfirmedSeq = fmap fst . dtConfirmed

-- ---------------------------------------------------------------------------
-- Baseline manager (receiver side)
-- ---------------------------------------------------------------------------

-- | Ring buffer of confirmed snapshots per connection (receiver side).
data BaselineManager a = BaselineManager
  { bmSnapshots :: !(Seq (BaselineSeq, a, MonoTime)),
    bmMaxSnapshots :: !Int,
    bmTimeoutNs :: !Word64
  }

-- | Create a new baseline manager.
newBaselineManager ::
  Int ->
  Milliseconds ->
  BaselineManager a
newBaselineManager maxSnapshots timeout =
  BaselineManager
    { bmSnapshots = Seq.empty,
      bmMaxSnapshots = maxSnapshots,
      bmTimeoutNs = msToNs timeout
    }

-- | Store a confirmed snapshot.
pushBaseline :: BaselineSeq -> a -> MonoTime -> BaselineManager a -> BaselineManager a
pushBaseline seqNum state now manager =
  let cleaned = evictExpired now manager
      trimmed =
        if Seq.length (bmSnapshots cleaned) >= bmMaxSnapshots cleaned
          then cleaned {bmSnapshots = Seq.drop 1 (bmSnapshots cleaned)}
          else cleaned
   in trimmed {bmSnapshots = bmSnapshots trimmed |> (seqNum, state, now)}

-- | Look up a baseline by sequence number.
getBaseline :: BaselineSeq -> BaselineManager a -> Maybe a
getBaseline seqNum manager =
  case Seq.findIndexR (\(s, _, _) -> s == seqNum) (bmSnapshots manager) of
    Nothing -> Nothing
    Just idx ->
      case Seq.lookup idx (bmSnapshots manager) of
        Nothing -> Nothing
        Just (_, state, _) -> Just state

-- | Remove expired snapshots.
baselineCleanup :: MonoTime -> BaselineManager a -> BaselineManager a
baselineCleanup = evictExpired

-- | Clear all stored baselines.
baselineReset :: BaselineManager a -> BaselineManager a
baselineReset manager = manager {bmSnapshots = Seq.empty}

-- | Number of stored baselines.
baselineCount :: BaselineManager a -> Int
baselineCount = Seq.length . bmSnapshots
{-# INLINE baselineCount #-}

-- | Whether the baseline buffer is empty.
baselineIsEmpty :: BaselineManager a -> Bool
baselineIsEmpty = Seq.null . bmSnapshots
{-# INLINE baselineIsEmpty #-}

-- | Evict expired snapshots (internal).
evictExpired :: MonoTime -> BaselineManager a -> BaselineManager a
evictExpired now manager =
  let timeout = bmTimeoutNs manager
   in manager
        { bmSnapshots =
            Seq.filter (\(_, _, ts) -> diffNs ts now < timeout) (bmSnapshots manager)
        }
