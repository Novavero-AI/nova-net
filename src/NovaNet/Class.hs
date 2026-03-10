-- |
-- Module      : NovaNet.Class
-- Description : Effect typeclasses for networking and time
--
-- Core effect abstractions that decouple protocol logic from IO.
-- All protocol code is polymorphic in these classes, enabling
-- real UDP, pure testing, and simulation backends.
module NovaNet.Class
  ( -- * Time
    MonadTime (..),
    elapsedNs,
    elapsedMs,
    elapsedSec,

    -- * Networking
    MonadNetwork (..),
    NetError (..),
    SendFailure (..),
  )
where

import Data.ByteString (ByteString)
import Data.Word (Word64)
import Network.Socket (SockAddr)
import NovaNet.Types (MonoTime (..), diffNs)

-- ---------------------------------------------------------------------------
-- Time
-- ---------------------------------------------------------------------------

-- | Monotonic time source. All protocol logic is parameterised over
-- this class so that tests can use deterministic time.
class (Monad m) => MonadTime m where
  getMonoTime :: m MonoTime

-- | Nanoseconds between @start@ and @now@. Caller must ensure
-- @now >= start@; underflow wraps (Word64 semantics).
elapsedNs :: MonoTime -> MonoTime -> Word64
elapsedNs = diffNs
{-# INLINE elapsedNs #-}

-- | Milliseconds between @start@ and @now@ (sub-ms precision).
elapsedMs :: MonoTime -> MonoTime -> Double
elapsedMs start now = fromIntegral (diffNs start now) / 1e6
{-# INLINE elapsedMs #-}

-- | Seconds between @start@ and @now@.
elapsedSec :: MonoTime -> MonoTime -> Double
elapsedSec start now = fromIntegral (diffNs start now) / 1e9
{-# INLINE elapsedSec #-}

-- ---------------------------------------------------------------------------
-- Networking
-- ---------------------------------------------------------------------------

-- | Specific reason a send operation failed.
data SendFailure
  = SendBufferFull
  | SendUnreachable
  | SendPermissionDenied
  | SendMessageTooLarge
  | SendErrno !Int -- OS error code for unrecognized failures
  deriving (Eq, Show)

-- | Network error from a send or close operation.
data NetError
  = NetSendFailed !SendFailure
  | NetSocketClosed
  | NetTimeout
  deriving (Eq, Show)

-- | UDP network operations. Superclass 'MonadTime' ensures every
-- networking backend also provides a time source.
class (MonadTime m) => MonadNetwork m where
  -- | Send a datagram to the given address. Non-blocking.
  netSend :: SockAddr -> ByteString -> m (Either NetError ())

  -- | Poll for an incoming datagram. Returns 'Right Nothing' if no data
  -- is available (non-blocking), 'Left' on error.
  netRecv :: m (Either NetError (Maybe (ByteString, SockAddr)))

  -- | Close the underlying socket.
  netClose :: m ()
