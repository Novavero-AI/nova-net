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

- **C99 hot path** — packet serialization, CRC32C (hardware-accelerated), ChaCha20-Poly1305 AEAD, ring buffers, fragmentation, message batching. Zero heap allocation on the hot path.
- **Haskell protocol brain** — connection state machines, handshake orchestration, congestion control, replication. Pure, testable, correct-by-construction.
- **Unsafe FFI boundary** — flat scalar arguments, no Storable marshalling. Just a function pointer jump.
- **Any platform** — C99 core compiles everywhere. Link from Haskell, Swift, Kotlin, Python, Zig, anything.
- **Effect abstraction** — `MonadNetwork` typeclass enables pure deterministic testing with no real sockets.
- **Zero external crypto deps** — ChaCha20-Poly1305 implemented from scratch (RFC 8439). CRC32C with SSE4.2/ARMv8 hardware acceleration and software fallback.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│           User Application                  │
├─────────────────────────────────────────────┤
│  Haskell Protocol Brain (38 modules)        │
│  Peer, Connection, Channel, Reliability,    │
│  Congestion, Handshake, Migration,          │
│  Replication, TestNet, Simulator            │
├─────────────────────────────────────────────┤
│  FFI Boundary (unsafe ccall, flat args)     │
│  NovaNet.FFI.{Packet,CRC32C,Seq,...}        │
├─────────────────────────────────────────────┤
│  C99 Hot Path (13 modules)                  │
│  nn_packet  nn_crc32c  nn_seq  nn_rtt       │
│  nn_fragment  nn_batch  nn_crypto           │
│  nn_bandwidth  nn_congestion                │
│  nn_ack_process  nn_siphash  nn_random      │
│  nn_wire  nn_ffi                            │
└─────────────────────────────────────────────┘
```

---

## C99 Modules

| Module | Purpose |
|--------|---------|
| `nn_wire.h` | Little-endian helpers, byte swap, buffer bounds (header-only) |
| `nn_packet` | 9-byte packet header (68-bit wire format, 8 packet types) |
| `nn_crc32c` | CRC32C integrity — SSE4.2, ARMv8 CRC hardware accel, software fallback |
| `nn_seq` | Sequence numbers (wraparound-safe), 256-entry ring buffers, ACK bitfield, loss window |
| `nn_rtt` | Jacobson/Karels RTT estimation (RFC 6298) |
| `nn_ack_process` | ACK bitfield processing against sent buffer and loss window |
| `nn_congestion` | Dual-layer: AIMD bandwidth + CWND packet window |
| `nn_fragment` | Fragment header (6 bytes LE), message splitting |
| `nn_batch` | Message batching/unbatching (count + length-prefixed) |
| `nn_crypto` | ChaCha20-Poly1305 AEAD (RFC 8439, from scratch, constant-time tag comparison) |
| `nn_bandwidth` | Sliding window bandwidth tracker |
| `nn_siphash` | SipHash-2-4 for HMAC cookies |
| `nn_random` | OS CSPRNG (getentropy/arc4random_buf/BCryptGenRandom) |
| `nn_ffi` | Flat-argument FFI entry points for Haskell |

---

## Features

- 68-bit packet headers (4-bit type + 16-bit seq + 16-bit ack + 32-bit ack bitfield)
- 5 delivery modes (Unreliable, UnreliableSequenced, ReliableUnordered, ReliableOrdered, ReliableSequenced)
- Dual-layer congestion control (binary mode + TCP New Reno window)
- ChaCha20-Poly1305 AEAD encryption with anti-replay nonce tracking
- Hardware-accelerated CRC32C (SSE4.2 on x86, ARMv8 CRC on aarch64)
- Jacobson/Karels RTT estimation with adaptive retransmit
- Large message fragmentation and reassembly
- Connection migration
- Delta compression, interest filtering, priority accumulation, snapshot interpolation
- All multi-byte wire fields are little-endian

---

## Status

**Feature complete.** Builds clean with `-Werror` on Linux, macOS, and Windows.

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
