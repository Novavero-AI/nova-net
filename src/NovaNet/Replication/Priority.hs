-- |
-- Module      : NovaNet.Replication.Priority
-- Description : Priority accumulator for bandwidth-limited entity replication
--
-- Tracks per-entity priority that grows over time, ensuring all
-- entities eventually get sent even at low priority.  'drainTop'
-- selects the highest-priority entities fitting a byte budget.
--
-- Fix #34: uses Double (not Float) for accumulation precision.
module NovaNet.Replication.Priority
  ( -- * Priority accumulator
    PriorityAccumulator,
    newPriorityAccumulator,

    -- * Entity management
    register,
    unregister,

    -- * Priority operations
    accumulate,
    applyModifier,
    drainTop,

    -- * Queries
    priorityCount,
    priorityIsEmpty,
    getPriority,
  )
where

import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..), comparing)

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

-- | Per-entity priority tracking entry.
data PriorityEntry = PriorityEntry
  { peBase :: !Double,
    peAccumulated :: !Double
  }
  deriving (Show)

-- | Accumulates priority per entity and drains the highest-priority
-- entities fitting a byte budget.
newtype PriorityAccumulator id = PriorityAccumulator
  { paEntries :: Map.Map id PriorityEntry
  }
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create an empty priority accumulator.
newPriorityAccumulator :: PriorityAccumulator id
newPriorityAccumulator = PriorityAccumulator Map.empty

-- ---------------------------------------------------------------------------
-- Entity management
-- ---------------------------------------------------------------------------

-- | Register an entity with a base priority (units/second).
-- Higher base priority = more frequent sends.
register :: (Ord id) => id -> Double -> PriorityAccumulator id -> PriorityAccumulator id
register entityId basePriority (PriorityAccumulator entries) =
  PriorityAccumulator $
    Map.insert
      entityId
      PriorityEntry {peBase = basePriority, peAccumulated = 0.0}
      entries

-- | Remove an entity from tracking.
unregister :: (Ord id) => id -> PriorityAccumulator id -> PriorityAccumulator id
unregister entityId (PriorityAccumulator entries) =
  PriorityAccumulator $ Map.delete entityId entries

-- ---------------------------------------------------------------------------
-- Priority operations
-- ---------------------------------------------------------------------------

-- | Advance accumulated priority for all entities by @dt@ seconds.
accumulate :: Double -> PriorityAccumulator id -> PriorityAccumulator id
accumulate dt (PriorityAccumulator entries) =
  PriorityAccumulator $
    Map.map
      (\e -> e {peAccumulated = peAccumulated e + peBase e * dt})
      entries

-- | Apply a priority modifier to a specific entity.
-- Use with interest management: closer entities get modifier > 1.0.
applyModifier :: (Ord id) => id -> Double -> PriorityAccumulator id -> PriorityAccumulator id
applyModifier entityId modifier (PriorityAccumulator entries) =
  PriorityAccumulator $
    Map.adjust
      (\e -> e {peAccumulated = peAccumulated e * modifier})
      entityId
      entries

-- | Drain the highest-priority entities fitting @budgetBytes@.
--
-- @sizeFunc@ returns the serialized size in bytes for a given entity ID.
-- Returns selected entity IDs (highest first) and the updated
-- accumulator with those entities' priorities reset to 0.
drainTop ::
  (Ord id) =>
  Int ->
  (id -> Int) ->
  PriorityAccumulator id ->
  ([id], PriorityAccumulator id)
drainTop budgetBytes sizeFunc (PriorityAccumulator entries) =
  let sorted =
        sortBy (comparing (Down . peAccumulated . snd)) $
          Map.toList entries
      (selected, _) = selectWithinBudget budgetBytes sizeFunc sorted []
      resetEntries =
        foldr
          (Map.adjust (\e -> e {peAccumulated = 0.0}))
          entries
          selected
   in (selected, PriorityAccumulator resetEntries)

-- | Select entities within budget (internal).
selectWithinBudget ::
  Int ->
  (id -> Int) ->
  [(id, PriorityEntry)] ->
  [id] ->
  ([id], Int)
selectWithinBudget remaining _ [] acc = (reverse acc, remaining)
selectWithinBudget remaining sizeFunc ((eid, _) : rest) acc =
  let size = sizeFunc eid
   in if size > remaining
        then selectWithinBudget remaining sizeFunc rest acc
        else selectWithinBudget (remaining - size) sizeFunc rest (eid : acc)

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Number of tracked entities.
priorityCount :: PriorityAccumulator id -> Int
priorityCount = Map.size . paEntries
{-# INLINE priorityCount #-}

-- | Whether the accumulator is empty.
priorityIsEmpty :: PriorityAccumulator id -> Bool
priorityIsEmpty = Map.null . paEntries
{-# INLINE priorityIsEmpty #-}

-- | Current accumulated priority for an entity.
getPriority :: (Ord id) => id -> PriorityAccumulator id -> Maybe Double
getPriority entityId (PriorityAccumulator entries) =
  peAccumulated <$> Map.lookup entityId entries
