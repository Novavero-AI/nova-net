# Changelog

## 0.1.0.0

### Initial Release

- Project scaffold: Cabal package, CI/CD (HLint, Ormolu, 3-platform matrix build, Hackage publish), BSD-3-Clause license.

### C99 Hot Path

- `nn_wire`: Little-endian read/write helpers, byte swap, buffer bounds checking (header-only).
- `nn_packet`: 9-byte packet header serialization (68-bit wire format, 8 packet types).
- `nn_crc32c`: CRC32C with SSE4.2 (x86_64), ARMv8 CRC (aarch64) hardware acceleration, software fallback.
- `nn_seq`: Wraparound-safe sequence numbers, 256-entry ring buffers, ACK bitfield processing, 256-bit loss window, SplitMix RNG.
- `nn_fragment`: Fragment header (6 bytes LE), message splitting.
- `nn_batch`: Message batching and unbatching (count + length-prefixed, LE).
- `nn_crypto`: ChaCha20-Poly1305 AEAD encryption (RFC 8439, from scratch, zero deps, constant-time tag comparison).
- `nn_bandwidth`: Sliding window bandwidth tracker.
- `nn_ffi`: Flat-argument FFI entry points for Haskell (no struct marshalling).

### Haskell FFI Bindings

- `NovaNet.Types`: Domain newtypes (ChannelId, SequenceNum, MessageId, MonoTime, NonceCounter).
- `NovaNet.FFI.Packet`: Packet header write/read via unsafe FFI.
- `NovaNet.FFI.CRC32C`: Hardware-accelerated CRC32C compute/append/validate.
- `NovaNet.FFI.Seq`: Sequence number comparison and difference.
- `NovaNet.FFI.Fragment`: Fragment header, count, and build.
- `NovaNet.FFI.Batch`: Batch format constants.
- `NovaNet.FFI.Crypto`: ChaCha20-Poly1305 encrypt/decrypt with error ADT.
- `NovaNet.FFI.Bandwidth`: Opaque ForeignPtr bandwidth tracker.

### Wire Format

- All multi-byte wire fields standardised to little-endian (fixes mixed endianness from gbnet-hs heritage).
