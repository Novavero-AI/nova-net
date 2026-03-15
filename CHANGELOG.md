# Changelog

## 0.3.0.0

Bug fix release from final audit.

### Bug Fixes

- Fixed payload header never prepended on send path — channel routing and fragment detection were broken on the wire
- Fixed DropOnFull eviction after sequence wraparound — was evicting newest message instead of oldest
- Fixed wrong sequence passed to CWND congestion controller — recovery phase exit used incoming packet seq instead of acked seq
- Fixed exception safety in runNetT/withNetT — recv thread and socket now cleaned up on exceptions
- Fixed simulator xorshift64 stuck at zero when seeded with MonoTime 0
- Fixed sendFragmented returning ErrInvalidChannel instead of ErrChannelSend MessageTooLarge

### API Changes (breaking)

- runNetT/withNetT specialized from MonadIO m to IO (exception safety requires it)
- Added omIsFragment field to OutgoingMessage
- Added sendFragmentMsg, allocateChannelSeq to Connection exports
- Added channelNextSeq to Channel exports

### Housekeeping

- Removed shadowed seqHalfRange in Channel (uses Config import)
- Fixed cabal version to match Hackage

## 0.2.0.0

Feature complete release.

### Protocol Core

- Jacobson/Karels RTT estimation (RFC 6298) in C
- ACK bitfield processing with 256-entry ring buffers and 256-bit loss window in C
- Dual-layer congestion control: AIMD bandwidth + CWND packet window with slow start, congestion avoidance, and fast recovery in C
- Reliable endpoint with send/receive tracking and ACK generation
- Five delivery modes: unreliable, unreliable sequenced, reliable unordered, reliable ordered, reliable sequenced
- Connection four-state FSM with timeout, keepalive, and graceful disconnect

### Subsystems

- Fragment split/reassemble with LRU eviction and timeout cleanup
- Binary search path MTU discovery
- Per-source rate limiting, connect tokens with replay detection, FNV-1a address hashing
- Quality/congestion/traffic counters

### Peer Layer

- SipHash-2-4 in C, OS CSPRNG via getentropy/BCryptGenRandom in C
- Four-way HMAC-cookie handshake with challenge-response
- Address migration with cooldown and encryption gate
- Wire protocol with little-endian encoding, CRC32C integrity, ChaCha20-Poly1305 AEAD
- Real UDP socket backend via MonadNetwork

### Replication

- NetworkDelta typeclass (diff/apply) with sender-side DeltaTracker and receiver-side BaselineManager
- Interest management: radius (squared distance) and grid (cell-based with distance weighting)
- Priority accumulator with budget-constrained drain
- Snapshot interpolation with playback delay and clamped lerp

### Testing Infrastructure

- Pure deterministic TestNet (State monad, xorshift64 RNG, MonadTime/MonadNetwork instances)
- Network simulator with token bucket bandwidth, configurable loss/latency/jitter/duplicates/reordering

### Port Fixes

Fourteen fixes carried over from the gbnet-hs audit: loss window feedback, CWND recovery exit, ring buffers (wraparound fix), single RTT sample per ACK, double precision, HMAC-bound cookies, migration encryption gate, max pending limit, simultaneous connect, disconnect reason codes, protocol ID validation, squared distance interest, grid weighting, double precision priority.

## 0.1.0.0

Initial release. Project scaffold, C99 hot path (8 modules), Haskell FFI bindings (9 modules), three-platform CI, Hackage name secured.
