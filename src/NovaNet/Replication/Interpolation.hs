-- |
-- Module      : NovaNet.Replication.Interpolation
-- Description : Snapshot interpolation for smooth client-side rendering
--
-- 'SnapshotBuffer' stores timestamped snapshots and interpolates
-- between them at a configurable playback delay, enabling smooth
-- rendering despite network jitter.
module NovaNet.Replication.Interpolation
  ( -- * Constants
    defaultBufferDepth,
    defaultPlaybackDelayMs,

    -- * Interpolatable typeclass
    Interpolatable (..),

    -- * Snapshot buffer
    SnapshotBuffer,
    newSnapshotBuffer,
    newSnapshotBufferWithConfig,

    -- * Operations
    pushSnapshot,
    sampleSnapshot,
    snapshotReset,

    -- * Queries
    snapshotCount,
    snapshotIsEmpty,
    snapshotReady,
    snapshotPlaybackDelayMs,

    -- * Configuration
    setPlaybackDelayMs,
  )
where

import Data.Sequence (Seq, ViewL (..), ViewR (..), (|>))
import qualified Data.Sequence as Seq

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | Default number of snapshots to buffer before interpolation begins.
defaultBufferDepth :: Int
defaultBufferDepth = 3

-- | Default playback delay in milliseconds behind the latest snapshot.
defaultPlaybackDelayMs :: Double
defaultPlaybackDelayMs = 100.0

-- ---------------------------------------------------------------------------
-- Interpolatable typeclass
-- ---------------------------------------------------------------------------

-- | Types that support linear interpolation between two states.
class Interpolatable a where
  -- | Linearly interpolate between @a@ and @b@ by factor @t@ in [0, 1].
  lerp :: a -> a -> Double -> a

instance Interpolatable Double where
  lerp a b t = a + (b - a) * t
  {-# INLINE lerp #-}

instance Interpolatable Float where
  lerp a b t = a + (b - a) * realToFrac t
  {-# INLINE lerp #-}

instance (Interpolatable a, Interpolatable b) => Interpolatable (a, b) where
  lerp (a1, b1) (a2, b2) t = (lerp a1 a2 t, lerp b1 b2 t)
  {-# INLINE lerp #-}

instance (Interpolatable a, Interpolatable b, Interpolatable c) => Interpolatable (a, b, c) where
  lerp (a1, b1, c1) (a2, b2, c2) t = (lerp a1 a2 t, lerp b1 b2 t, lerp c1 c2 t)
  {-# INLINE lerp #-}

-- ---------------------------------------------------------------------------
-- Snapshot buffer
-- ---------------------------------------------------------------------------

-- | A timestamped snapshot (internal).
data TimestampedSnapshot a = TimestampedSnapshot
  { tsTimestamp :: !Double,
    tsState :: !a
  }

-- | Ring buffer of timestamped snapshots with interpolation sampling.
data SnapshotBuffer a = SnapshotBuffer
  { sbSnapshots :: !(Seq (TimestampedSnapshot a)),
    sbBufferDepth :: !Int,
    sbPlaybackDelayMs :: !Double
  }

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- | Create a snapshot buffer with default settings.
newSnapshotBuffer :: SnapshotBuffer a
newSnapshotBuffer =
  SnapshotBuffer
    { sbSnapshots = Seq.empty,
      sbBufferDepth = defaultBufferDepth,
      sbPlaybackDelayMs = defaultPlaybackDelayMs
    }

-- | Create a snapshot buffer with custom settings.
newSnapshotBufferWithConfig :: Int -> Double -> SnapshotBuffer a
newSnapshotBufferWithConfig depth delay =
  SnapshotBuffer
    { sbSnapshots = Seq.empty,
      sbBufferDepth = depth,
      sbPlaybackDelayMs = delay
    }

-- ---------------------------------------------------------------------------
-- Operations
-- ---------------------------------------------------------------------------

-- | Push a new snapshot with its server timestamp (milliseconds).
-- Out-of-order snapshots are dropped.
pushSnapshot :: Double -> a -> SnapshotBuffer a -> SnapshotBuffer a
pushSnapshot timestamp state buffer =
  case Seq.viewr (sbSnapshots buffer) of
    EmptyR ->
      buffer {sbSnapshots = Seq.singleton (TimestampedSnapshot timestamp state)}
    _ :> newest
      | timestamp <= tsTimestamp newest -> buffer
      | otherwise ->
          let appended = sbSnapshots buffer |> TimestampedSnapshot timestamp state
              maxEntries = sbBufferDepth buffer * 2
              trimmed =
                if Seq.length appended > maxEntries
                  then Seq.drop (Seq.length appended - maxEntries) appended
                  else appended
           in buffer {sbSnapshots = trimmed}

-- | Sample an interpolated state at @renderTime@ (milliseconds).
-- Returns 'Nothing' if fewer than 2 snapshots are buffered.
sampleSnapshot :: (Interpolatable a) => Double -> SnapshotBuffer a -> Maybe a
sampleSnapshot renderTime buffer =
  let targetTime = renderTime - sbPlaybackDelayMs buffer
      snapshots = sbSnapshots buffer
   in if Seq.length snapshots < 2
        then Nothing
        else findAndInterpolate targetTime snapshots

-- | Clear all buffered snapshots.
snapshotReset :: SnapshotBuffer a -> SnapshotBuffer a
snapshotReset buffer = buffer {sbSnapshots = Seq.empty}

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

-- | Number of buffered snapshots.
snapshotCount :: SnapshotBuffer a -> Int
snapshotCount = Seq.length . sbSnapshots
{-# INLINE snapshotCount #-}

-- | Whether the buffer is empty.
snapshotIsEmpty :: SnapshotBuffer a -> Bool
snapshotIsEmpty = Seq.null . sbSnapshots
{-# INLINE snapshotIsEmpty #-}

-- | Whether enough snapshots are buffered to begin interpolation.
snapshotReady :: SnapshotBuffer a -> Bool
snapshotReady buffer = Seq.length (sbSnapshots buffer) >= sbBufferDepth buffer
{-# INLINE snapshotReady #-}

-- | Get the playback delay in milliseconds.
snapshotPlaybackDelayMs :: SnapshotBuffer a -> Double
snapshotPlaybackDelayMs = sbPlaybackDelayMs
{-# INLINE snapshotPlaybackDelayMs #-}

-- | Set the playback delay in milliseconds.
setPlaybackDelayMs :: Double -> SnapshotBuffer a -> SnapshotBuffer a
setPlaybackDelayMs delay buffer = buffer {sbPlaybackDelayMs = delay}

-- ---------------------------------------------------------------------------
-- Interpolation (internal)
-- ---------------------------------------------------------------------------

-- | Find bracketing snapshots and interpolate.
findAndInterpolate :: (Interpolatable a) => Double -> Seq (TimestampedSnapshot a) -> Maybe a
findAndInterpolate targetTime snapshots =
  case findBracket targetTime (Seq.viewl snapshots) of
    Just (a, b) ->
      let duration = tsTimestamp b - tsTimestamp a
       in if duration <= 0.0
            then Just (tsState a)
            else
              let t = (targetTime - tsTimestamp a) / duration
                  tClamped = max 0.0 (min 1.0 t)
               in Just (lerp (tsState a) (tsState b) tClamped)
    Nothing ->
      -- Target outside range — return boundary
      case (Seq.viewl snapshots, Seq.viewr snapshots) of
        (first :< _, _ :> lastSnap)
          | targetTime > tsTimestamp lastSnap -> Just (tsState lastSnap)
          | targetTime < tsTimestamp first -> Just (tsState first)
        _ -> Nothing

-- | Find two snapshots bracketing the target time.
findBracket ::
  Double ->
  ViewL (TimestampedSnapshot a) ->
  Maybe (TimestampedSnapshot a, TimestampedSnapshot a)
findBracket _ EmptyL = Nothing
findBracket _ (_ :< rest) | Seq.null rest = Nothing
findBracket targetTime (a :< rest) =
  case Seq.viewl rest of
    b :< _ ->
      if targetTime >= tsTimestamp a && targetTime <= tsTimestamp b
        then Just (a, b)
        else findBracket targetTime (Seq.viewl rest)
    EmptyL -> Nothing
