-- |
-- Module      : NovaNet.Peer.Migration
-- Description : Connection migration when packets arrive from a new address
--
-- Moves a Connection to a new PeerId when an incoming packet matches
-- an existing connection's sequence space.  Respects migration policy
-- and cooldown.
--
-- Fix #5: migration disabled when encryption key is Nothing.
module NovaNet.Peer.Migration
  ( -- * Migration
    findMigrationCandidate,
    migrateConnection,
  )
where

import qualified Data.Map.Strict as Map
import Data.Word (Word16, Word64)
import NovaNet.Config
import NovaNet.Connection (Connection, connectionState, resetTransportMetrics)
import qualified NovaNet.Connection as Conn
import NovaNet.FFI.Seq (seqDiff)
import NovaNet.Reliability (reLocalSeq)
import NovaNet.Types

-- ---------------------------------------------------------------------------
-- Migration
-- ---------------------------------------------------------------------------

-- | Find a connection that matches the incoming sequence number.
-- Only considers migration if the policy allows it AND an encryption
-- key is set (fix #5).  Returns the matching PeerId if found.
findMigrationCandidate ::
  Word16 ->
  PeerId ->
  NetworkConfig ->
  Map.Map PeerId Connection ->
  Map.Map Word64 MonoTime ->
  MonoTime ->
  Maybe PeerId
findMigrationCandidate incomingSeq newPeerId cfg conns cooldowns now
  | ncMigrationPolicy cfg /= MigrationEnabled = Nothing
  | Nothing <- ncEncryptionKey cfg = Nothing
  | otherwise =
      let maxDist = fromIntegral (ncMaxSequenceDistance cfg)
          candidates =
            [ existingPeer
            | (existingPeer, conn) <- Map.toList conns,
              existingPeer /= newPeerId,
              connectionState conn == Connected,
              let localSeq = unSequenceNum (reLocalSeq (Conn.connReliability conn)),
              abs (seqDiff incomingSeq localSeq) <= maxDist,
              not (isCoolingDown (Conn.connClientSalt conn) cooldowns now)
            ]
       in case candidates of
            (peer : _) -> Just peer
            [] -> Nothing

-- | Check if a connection salt is in cooldown.
isCoolingDown :: Word64 -> Map.Map Word64 MonoTime -> MonoTime -> Bool
isCoolingDown salt cooldowns now =
  case Map.lookup salt cooldowns of
    Nothing -> False
    Just cooldownStart -> diffNs cooldownStart now < migrationCooldownNs

-- | Migrate a connection from an old PeerId to a new PeerId.
-- Moves Connection (which owns FragmentAssembler), resets transport
-- metrics, records cooldown, returns PeerMigrated event.
migrateConnection ::
  PeerId ->
  PeerId ->
  MonoTime ->
  Map.Map PeerId Connection ->
  Map.Map Word64 MonoTime ->
  IO (Map.Map PeerId Connection, Map.Map Word64 MonoTime, [PeerEvent])
migrateConnection oldPeerId newPeerId now conns cooldowns =
  case Map.lookup oldPeerId conns of
    Nothing -> pure (conns, cooldowns, [])
    Just conn -> do
      resetConn <- resetTransportMetrics conn
      let conns2 = Map.delete oldPeerId (Map.insert newPeerId resetConn conns)
          cooldowns2 = Map.insert (Conn.connClientSalt conn) now cooldowns
      pure (conns2, cooldowns2, [PeerMigrated oldPeerId newPeerId])
