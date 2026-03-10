-- |
-- Module      : NovaNet.Security
-- Description : Rate limiting, connect tokens, and address hashing
--
-- Pure Haskell module.  Per-source rate limiting with self-cleaning
-- sliding windows.  Connect tokens with expiration and replay
-- detection via a bounded token validator.  FNV-1a address hashing
-- for O(1) source keying.
module NovaNet.Security
  ( -- * Rate Limiter
    RateLimiter,
    newRateLimiter,
    rateLimiterAllow,
    rateLimiterDropCount,

    -- * Connect Tokens
    ConnectToken,
    newConnectToken,
    isTokenExpired,
    tokenClientId,
    tokenUserData,

    -- * Token Validator
    TokenValidator,
    TokenError (..),
    newTokenValidator,
    validateToken,
    validatorCleanup,
    validatorEvictedCount,

    -- * Address Hashing
    addressKey,
  )
where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.List (foldl')
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Network.Socket (SockAddr (..))
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- | FNV-1a offset basis (64-bit).
fnvOffsetBasis :: Word64
fnvOffsetBasis = 14695981039346656037

-- | FNV-1a prime (64-bit).
fnvPrime :: Word64
fnvPrime = 1099511628211

-- | Rate limiter sliding window: 1 second in nanoseconds.
rateLimiterWindowNs :: Word64
rateLimiterWindowNs = 1000 * 1000000

-- | Cleanup interval: 5 seconds in nanoseconds.
cleanupIntervalNs :: Word64
cleanupIntervalNs = 5000 * 1000000

-- ---------------------------------------------------------------------------
-- Address hashing (FNV-1a)
-- ---------------------------------------------------------------------------

-- | Hash a socket address to a 64-bit key using FNV-1a.
-- Used for per-source rate limiting without storing full addresses.
addressKey :: SockAddr -> Word64
addressKey (SockAddrInet port host) =
  fnvMix (fnvMix fnvOffsetBasis (fromIntegral port)) (fromIntegral host)
addressKey (SockAddrInet6 port _flow (h1, h2, h3, h4) _scope) =
  foldl'
    fnvMix
    fnvOffsetBasis
    [fromIntegral port, fromIntegral h1, fromIntegral h2, fromIntegral h3, fromIntegral h4]
addressKey (SockAddrUnix _) = fnvOffsetBasis

fnvMix :: Word64 -> Word64 -> Word64
fnvMix hash val = (hash `xor` val) * fnvPrime
{-# INLINE fnvMix #-}

-- ---------------------------------------------------------------------------
-- Rate Limiter
-- ---------------------------------------------------------------------------

-- | Per-source rate limiter with self-cleaning sliding windows.
-- Keys are FNV-1a hashes of source addresses.
data RateLimiter = RateLimiter
  { rlRequests :: !(Map.Map Word64 [MonoTime]),
    rlMaxPerSecond :: !Int,
    rlLastCleanup :: !MonoTime,
    rlDropCount :: !Word64
  }

-- | Create a rate limiter allowing the given requests per second.
newRateLimiter :: Int -> MonoTime -> RateLimiter
newRateLimiter maxPerSec now =
  RateLimiter
    { rlRequests = Map.empty,
      rlMaxPerSecond = maxPerSec,
      rlLastCleanup = now,
      rlDropCount = 0
    }

-- | Check if a request from the given source is allowed.
-- Returns whether the request is allowed and the updated limiter.
-- Automatically cleans up stale entries every 5 seconds.
rateLimiterAllow :: Word64 -> MonoTime -> RateLimiter -> (Bool, RateLimiter)
rateLimiterAllow key now rl =
  let recent = filterRecent now (Map.findWithDefault [] key (rlRequests rl))
      allowed = length recent < rlMaxPerSecond rl
      newTimestamps
        | allowed = now : recent
        | otherwise = recent
      updated =
        maybeCleanup now $
          rl
            { rlRequests = Map.insert key newTimestamps (rlRequests rl),
              rlDropCount = rlDropCount rl + if allowed then 0 else 1
            }
   in (allowed, updated)

-- | Total number of rate-limited (dropped) requests.
rateLimiterDropCount :: RateLimiter -> Word64
rateLimiterDropCount = rlDropCount
{-# INLINE rateLimiterDropCount #-}

-- | Keep only timestamps within the last second.
filterRecent :: MonoTime -> [MonoTime] -> [MonoTime]
filterRecent now = filter (\t -> diffNs t now < rateLimiterWindowNs)

-- | Remove empty entries every cleanup interval.
maybeCleanup :: MonoTime -> RateLimiter -> RateLimiter
maybeCleanup now rl
  | diffNs (rlLastCleanup rl) now < cleanupIntervalNs = rl
  | otherwise =
      rl
        { rlRequests =
            Map.filter (not . null) $
              Map.map (filterRecent now) (rlRequests rl),
          rlLastCleanup = now
        }

-- ---------------------------------------------------------------------------
-- Connect Tokens
-- ---------------------------------------------------------------------------

-- | A token presented by a client during connection.
-- Contains a client identifier, expiration, and optional user data.
data ConnectToken = ConnectToken
  { ctClientId :: !Word64,
    ctCreateTime :: !MonoTime,
    ctExpireDurationNs :: !Word64,
    ctUserData :: !ByteString
  }

-- | Create a connect token.
newConnectToken :: Word64 -> Milliseconds -> ByteString -> MonoTime -> ConnectToken
newConnectToken clientId expireMs userData now =
  ConnectToken
    { ctClientId = clientId,
      ctCreateTime = now,
      ctExpireDurationNs = msToNs expireMs,
      ctUserData = userData
    }

-- | Has this token expired?
isTokenExpired :: MonoTime -> ConnectToken -> Bool
isTokenExpired now token = diffNs (ctCreateTime token) now >= ctExpireDurationNs token
{-# INLINE isTokenExpired #-}

-- | The client identifier from a token.
tokenClientId :: ConnectToken -> Word64
tokenClientId = ctClientId
{-# INLINE tokenClientId #-}

-- | The user data from a token.
tokenUserData :: ConnectToken -> ByteString
tokenUserData = ctUserData
{-# INLINE tokenUserData #-}

-- ---------------------------------------------------------------------------
-- Token Validator
-- ---------------------------------------------------------------------------

-- | Why token validation failed.
data TokenError
  = TokenExpired
  | TokenReplayed
  deriving (Eq, Show)

-- | Server-side validator that tracks used tokens to prevent replay.
-- Bounded by max capacity with LRU eviction.
data TokenValidator = TokenValidator
  { tvUsedTokens :: !(Map.Map Word64 MonoTime),
    tvTokenLifetimeNs :: !Word64,
    tvMaxTracked :: !Int,
    tvEvictedCount :: !Word64
  }

-- | Create a token validator with the given token lifetime and capacity.
newTokenValidator :: Milliseconds -> Int -> TokenValidator
newTokenValidator lifetime maxTracked =
  TokenValidator
    { tvUsedTokens = Map.empty,
      tvTokenLifetimeNs = msToNs lifetime,
      tvMaxTracked = maxTracked,
      tvEvictedCount = 0
    }

-- | Validate a connect token.  Returns the client ID on success,
-- or an error if the token is expired or has been seen before.
-- Automatically enforces capacity limits.
validateToken ::
  ConnectToken ->
  MonoTime ->
  TokenValidator ->
  (Either TokenError Word64, TokenValidator)
validateToken token now tv
  | isTokenExpired now token = (Left TokenExpired, tv)
  | Map.member cid (tvUsedTokens tv) = (Left TokenReplayed, tv)
  | otherwise =
      let inserted = tv {tvUsedTokens = Map.insert cid now (tvUsedTokens tv)}
          enforced = enforceLimit now inserted
       in (Right cid, enforced)
  where
    cid = ctClientId token

-- | Remove expired tokens.
validatorCleanup :: MonoTime -> TokenValidator -> TokenValidator
validatorCleanup now tv =
  tv
    { tvUsedTokens =
        Map.filter (\created -> diffNs created now < tvTokenLifetimeNs tv) (tvUsedTokens tv)
    }

-- | Total tokens evicted due to capacity limits.
validatorEvictedCount :: TokenValidator -> Word64
validatorEvictedCount = tvEvictedCount
{-# INLINE validatorEvictedCount #-}

-- | Ensure the validator stays within capacity.
-- First cleans expired tokens, then evicts oldest if still over.
enforceLimit :: MonoTime -> TokenValidator -> TokenValidator
enforceLimit now tv
  | Map.size (tvUsedTokens cleaned) <= tvMaxTracked cleaned = cleaned
  | otherwise = evictOldest cleaned
  where
    cleaned = validatorCleanup now tv

-- | Remove the oldest tracked token.
evictOldest :: TokenValidator -> TokenValidator
evictOldest tv
  | Map.null (tvUsedTokens tv) = tv
  | otherwise =
      let (minKey, minTime) = Map.findMin (tvUsedTokens tv)
          (oldest, _) =
            Map.foldlWithKey'
              ( \(bestKey, bestTime) key time ->
                  if time < bestTime then (key, time) else (bestKey, bestTime)
              )
              (minKey, minTime)
              (tvUsedTokens tv)
       in tv
            { tvUsedTokens = Map.delete oldest (tvUsedTokens tv),
              tvEvictedCount = tvEvictedCount tv + 1
            }
