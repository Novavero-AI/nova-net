-- |
-- Module      : NovaNet.Replication.Interest
-- Description : Area-of-interest filtering for entity replication
--
-- Determines which entities are relevant to a given observer,
-- reducing bandwidth by only replicating nearby entities.
--
-- Two strategies: 'RadiusInterest' for sphere-based filtering,
-- 'GridInterest' for cell-based spatial partitioning.
--
-- Fix #29: squared distance used throughout (no sqrt).
-- Fix #30: GridInterest provides distance-based priority modifier.
module NovaNet.Replication.Interest
  ( -- * Position type
    Position,

    -- * Interest manager typeclass
    InterestManager (..),

    -- * Radius-based interest
    RadiusInterest,
    newRadiusInterest,
    radiusInterestRadius,

    -- * Grid-based interest
    GridInterest,
    newGridInterest,
    gridInterestCellSize,
  )
where

-- | 3D position as (x, y, z).
type Position = (Double, Double, Double)

-- | Typeclass for determining entity relevance to an observer.
class InterestManager a where
  -- | Is the entity at @entityPos@ relevant to the observer at @observerPos@?
  relevant :: a -> Position -> Position -> Bool

  -- | Priority modifier for the entity relative to the observer.
  -- Values > 1.0 increase priority, < 1.0 decrease it.
  -- Default: 1.0 (no modification).
  priorityMod :: a -> Position -> Position -> Double
  priorityMod _ _ _ = 1.0

-- ---------------------------------------------------------------------------
-- Radius-based interest
-- ---------------------------------------------------------------------------

-- | Sphere-based interest: entities within @radius@ are relevant.
-- Provides distance-based priority: closer entities get higher priority.
data RadiusInterest = RadiusInterest
  { riRadius :: !Double,
    riRadiusSq :: !Double
  }
  deriving (Show)

-- | Create a radius-based interest manager.
newRadiusInterest :: Double -> RadiusInterest
newRadiusInterest radius =
  RadiusInterest
    { riRadius = radius,
      riRadiusSq = radius * radius
    }

-- | Get the radius.
radiusInterestRadius :: RadiusInterest -> Double
radiusInterestRadius = riRadius
{-# INLINE radiusInterestRadius #-}

instance InterestManager RadiusInterest where
  relevant ri entityPos observerPos =
    distanceSq entityPos observerPos <= riRadiusSq ri

  -- Fix #29: no sqrt — linear falloff via squared distance ratio.
  -- priority = 1.0 - (distSq / radiusSq), clamped to [0, 1].
  priorityMod ri entityPos observerPos =
    let dSq = distanceSq entityPos observerPos
        rSq = riRadiusSq ri
     in if dSq >= rSq
          then 0.0
          else 1.0 - (dSq / rSq)

-- ---------------------------------------------------------------------------
-- Grid-based interest
-- ---------------------------------------------------------------------------

-- | Cell-based interest: entities in the same or neighboring cells
-- are relevant.  More efficient than radius checks for large entity
-- counts when combined with spatial hashing.
data GridInterest = GridInterest
  { giCellSize :: !Double,
    giInvCellSize :: !Double
  }
  deriving (Show)

-- | Create a grid-based interest manager.
newGridInterest :: Double -> GridInterest
newGridInterest cellSize =
  GridInterest
    { giCellSize = cellSize,
      giInvCellSize = 1.0 / cellSize
    }

-- | Get the cell size.
gridInterestCellSize :: GridInterest -> Double
gridInterestCellSize = giCellSize
{-# INLINE gridInterestCellSize #-}

instance InterestManager GridInterest where
  relevant gi entityPos observerPos =
    let (ex, ey, ez) = toCell gi entityPos
        (ox, oy, oz) = toCell gi observerPos
     in abs (ex - ox) <= 1 && abs (ey - oy) <= 1 && abs (ez - oz) <= 1

  -- Fix #30: distance-based weighting for grid interest.
  -- Same cell = 1.0, neighboring cell = falloff based on distance.
  priorityMod gi entityPos observerPos =
    let (ex, ey, ez) = toCell gi entityPos
        (ox, oy, oz) = toCell gi observerPos
        dx = abs (ex - ox)
        dy = abs (ey - oy)
        dz = abs (ez - oz)
     in if dx > 1 || dy > 1 || dz > 1
          then 0.0
          else
            let cellDist = fromIntegral (dx + dy + dz) :: Double
                maxDist = 3.0
             in 1.0 - (cellDist / maxDist)

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Squared distance between two positions.
distanceSq :: Position -> Position -> Double
distanceSq (x1, y1, z1) (x2, y2, z2) =
  let dx = x1 - x2
      dy = y1 - y2
      dz = z1 - z2
   in dx * dx + dy * dy + dz * dz
{-# INLINE distanceSq #-}

-- | Convert position to grid cell coordinates.
toCell :: GridInterest -> Position -> (Int, Int, Int)
toCell gi (x, y, z) =
  let inv = giInvCellSize gi
   in (floor (x * inv), floor (y * inv), floor (z * inv))
{-# INLINE toCell #-}
