<div align="center">
<h1>nova-net</h1>
<p><strong>General-Purpose Reliable UDP</strong></p>
<p>C99 hot path. Haskell protocol brain. Any platform with a C compiler.</p>
<p>

[![CI](https://github.com/Novavero-AI/nova-net/actions/workflows/ci.yml/badge.svg)](https://github.com/Novavero-AI/nova-net/actions/workflows/ci.yml)
[![Hackage](https://img.shields.io/hackage/v/nova-net.svg)](https://hackage.haskell.org/package/nova-net)
![Haskell](https://img.shields.io/badge/haskell-GHC%209.8-purple)
![C99](https://img.shields.io/badge/C99-hot%20path-orange)
![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)

</p>
</div>

---

## What is nova-net?

A general-purpose reliable UDP networking library. C99 handles the hot path (serialization, send/recv, ack processing, crypto). Haskell handles the protocol logic (connection state machines, congestion control, replication). Successor to [gbnet-hs](https://hackage.haskell.org/package/gbnet-hs).

- **C99 hot path** — packet serialization, socket I/O, ACK bitfield processing, CRC32C, ChaCha20-Poly1305. No heap allocation. Sub-10ns targets.
- **Haskell protocol brain** — connection state machines, handshake orchestration, congestion control, replication. Pure, testable, correct-by-construction.
- **Unsafe FFI boundary** — Haskell calls C with zero marshalling overhead. Just a function pointer jump.
- **Any platform** — C99 core compiles everywhere. Link from Haskell, Swift, Kotlin, Python, Zig, anything.
- **Effect abstraction** — `MonadNetwork` typeclass enables pure deterministic testing with no real sockets.

---

## Architecture

```
┌─────────────────────────────────────────┐
│           User Application              │
├─────────────────────────────────────────┤
│  Haskell Protocol Brain                 │
│  Connection, Peer, Handshake,           │
│  Congestion, Replication                │
├─────────────────────────────────────────┤
│  Unsafe FFI Boundary                    │
│  foreign import ccall unsafe            │
├─────────────────────────────────────────┤
│  C99 Hot Path                           │
│  nn_packet, nn_serialize, nn_socket,    │
│  nn_reliability, nn_crypto, nn_channel  │
└─────────────────────────────────────────┘
```

---

## Heritage

nova-net inherits the protocol design from [gbnet-hs](https://hackage.haskell.org/package/gbnet-hs), a production-tested Haskell networking library:

- 68-bit packet headers (4-bit type + 16-bit seq + 16-bit ack + 32-bit ack bitfield)
- 5 delivery modes (Unreliable, UnreliableSequenced, ReliableUnordered, ReliableOrdered, ReliableSequenced)
- Dual-layer congestion control (binary mode + TCP New Reno window)
- ChaCha20-Poly1305 AEAD encryption with anti-replay
- Jacobson/Karels RTT estimation with adaptive retransmit
- Delta compression, interest filtering, priority accumulation, snapshot interpolation

Same protocol. C muscles.

---

## Build & Test

Requires [GHCup](https://www.haskell.org/ghcup/) with GHC >= 9.8.

```bash
cabal build                              # Build library
cabal test                               # Run all tests
cabal build --ghc-options="-Werror"      # Warnings as errors
cabal bench                              # Run benchmarks
```

---

## Contributing

```bash
cabal test && cabal build --ghc-options="-Werror"
```

---

<p align="center">
  <sub>BSD-3-Clause · <a href="https://github.com/Novavero-AI">Novavero AI</a></sub>
</p>
