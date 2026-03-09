# CLAUDE.md

## Rules

- **Only commit and push when explicitly instructed.** Never amend commits. Never add `Co-Authored-By` headers.
- Run `cabal test` and `cabal build --ghc-options="-Werror"` before considering any change complete. Run `cabal bench` for performance-sensitive changes — no regressions allowed.
- **`-Wall -Wcompat` clean.** All Haskell code compiles without warnings under `-Wall -Wcompat`. Warnings are errors in CI — no exceptions, no suppressions.
- **C99 compiles with `-Wall -Wextra -Wpedantic -Werror`.** No warnings in C code either.

## Haskell Style

- **Pure by default.** Everything is a pure function unless it fundamentally cannot be. IO is a composed effect description, not an escape hatch. Prefer `foldl'` over `foldM`, pure state transforms over `IORef` mutation, `runXxxT` composed at one boundary over `liftIO` threaded throughout. Separate decisions (pure) from effects (composed IO).
- **Abstract over effects.** Core logic is polymorphic in its effect via typeclasses (`MonadNetwork`, `MonadTime`), never tied to concrete IO. New capabilities get a typeclass, not an IO dependency.
- **Let the types guide.** Write the type signature first. If the type is right, the implementation follows. If the implementation is awkward, the type is wrong. Types are the design — code is the consequence.
- **Parametricity.** Write the most general type that works. `a -> a` has one implementation. `(Foldable t) => t a -> [a]` constrains you more than `[a] -> [a]` does. The more polymorphic the signature, the fewer places for bugs to hide.
- **Total functions only.** Never use `head`, `tail`, `!!`, `fromJust`, `read`, or any partial function. Use pattern matching, `maybe`, `either`, `BS.uncons`, safe alternatives. Every function must handle every input. Reserve `error`/`undefined` for genuinely unreachable branches (with a comment proving why).
- **Strict by default.** Bang patterns on all data fields and accumulators. `Data.Map.Strict` over `Data.Map.Lazy`. Strict `foldl'` over lazy `foldl`. No space leaks. Do not over-strict function arguments — only fields and accumulators need bangs; forcing every lambda argument can prevent beneficial laziness in recursive code. This is a networking library — performance is non-negotiable.
- **Types encode invariants.** Newtypes for domain concepts (`MonoTime`, `ChannelId`, `PeerId`). Exhaustive pattern matches. Make illegal states unrepresentable. No stringly-typed code, no boolean blindness.
- **Lawful abstractions.** Every typeclass instance must respect its laws. `Monoid` must be associative with identity. `Functor` must preserve composition. If you can't satisfy the laws, don't write the instance.
- **Minimal constraints.** Don't ask for `MonadNetwork` when `MonadTime` suffices. Don't require `Ord` when `Eq` is enough. Every constraint in a signature is a promise about what the function actually needs — keep it honest.
- **Small, composable functions.** Each function does one thing. Compose pipelines of pure transforms. If a function is hard to name, it's doing too much.
- **Named constants.** No magic numbers or hardcoded strings anywhere. Every threshold, size, rate, and timeout gets a name.
- **No prime-mark variables.** Never use `x'`, `x''`, `s'`, etc. Use descriptive names: `decoded`, `frozen`, `advanced`, `mutated`, `rng1`/`rng2`. Prime marks are cryptic and scale poorly.
- **Idiomatic patterns.** Guards over nested if/then/else. Pattern matching over boolean checks. `where` for local definitions. Explicit export lists on all modules. No orphan instances.
- **Clean module structure.** Group by responsibility. Each module has a clear single purpose, an explicit export list, and a documented role.

## C99 Style

- **C99 standard only.** No compiler extensions, no C11/C23. Compiles with `gcc` and `clang` on Linux, macOS, Windows (MSVC via C99 mode).
- **`nn_` prefix on all public symbols.** Every exported function, type, constant, and macro starts with `nn_` to avoid namespace collisions.
- **Static by default.** Internal functions are `static` or `static inline`. Only the public API is extern. Minimize the symbol table.
- **No heap allocation on the hot path.** Send/recv/serialize/ack processing uses stack buffers and caller-provided memory. `malloc` is for setup/teardown only.
- **Explicit sizes.** `uint8_t`, `uint16_t`, `uint32_t`, `uint64_t` from `<stdint.h>`. Never `int` or `long` for wire data. `size_t` for buffer lengths.
- **Bounds checking.** Every buffer read/write validates length first. No unchecked pointer arithmetic. Assert preconditions in debug builds.
- **Little-endian wire format.** All multi-byte fields on the wire are little-endian. Use explicit conversion helpers, never assume host byte order.
- **Named constants.** `#define NN_PACKET_HEADER_SIZE 9`, never bare `9`. Same rule as Haskell — every magic number gets a name.
- **No global mutable state.** All state lives in structs passed by pointer. Functions are reentrant and thread-safe where documented.
- **One function, one job.** Same composability principle as Haskell. If a C function is hard to name, split it.
- **Header discipline.** Every `.c` file has a corresponding `.h`. Headers use include guards (`#ifndef NN_PACKET_H`). Headers contain only declarations, never definitions (except `static inline`).

## FFI Boundary

- **Unsafe FFI for hot path.** `foreign import ccall unsafe` for all C functions called in the send/recv/serialize loop. No GC safe points, no marshalling overhead — just a function pointer jump.
- **Safe FFI for blocking ops.** `foreign import ccall safe` only for socket recv (which blocks) and setup/teardown.
- **C owns the data layout.** Structs are defined in C headers. Haskell `Storable` instances match the C layout exactly. No intermediate representations.
- **Pointer passing.** Haskell passes `Ptr` to C functions that operate on buffers in place. No ByteString copying across the boundary.

## Context

General-purpose reliable UDP networking library. C99 hot path for maximum performance on any platform. Haskell protocol brain for correct-by-construction logic. Successor to gbnet-hs — same protocol design, C muscles.
