# Castellum native core (Rust) + macOS app (Swift)

This is the Castellum stack: a Rust core library exposed to a Swift/AppKit
macOS UI over a narrow C ABI. It replaced an earlier Electron/TypeScript
prototype that was retired once the native app reached parity; nothing in this
repository depends on it.

> **Pre-1.0:** there is no installed base and local data is disposable, so there
> is **no data migration** path between versions yet: the app re-syncs from IMAP
> into a fresh schema when it must.

## Layout

```
native/                           Rust Cargo workspace
  crates/castellum-models/        dependency-free DTOs + CastellumStatus (ABI codes)
  crates/castellum-db/            SQLite storage, FTS5 search, migrations
  crates/castellum-mail/          message parsing, HTML sanitising, compose helpers
  crates/castellum-providers/     provider traits shared by the adapters below
  crates/castellum-provider-imap/ IMAP sync (imap-codec based session)
  crates/castellum-provider-smtp/ SMTP send
  crates/castellum-provider-ollama/ local-model client with the private-address egress guard
  crates/castellum-provider-mlx/  experimental MLX provider (Cargo feature, off by default)
  crates/castellum-core/          sync engine, operation queue, orchestration
  crates/castellum-ffi/           C ABI (staticlib+cdylib); include/castellum.h
  crates/castellum-testutil/      test-only scratch directory helper
../apple/                         XcodeGen macOS app that links the Rust staticlib
```

## Prerequisites

- Rust stable via `rustup` (developed with cargo 1.96).
- Xcode + Command Line Tools (developed with Xcode 26.6 / Swift 6.3) — for `swift`,
  `clang`, and the CoreFoundation/Security frameworks the Rust staticlib links.
- `xcodegen` (`brew install xcodegen`) to generate the Xcode project.

## Build, test, run

```bash
# Rust core + FFI (from repo root)
cargo fmt   --all --check          --manifest-path native/Cargo.toml
cargo clippy --all-targets -- -D warnings  # run inside native/, or -p per crate
cargo test                          --manifest-path native/Cargo.toml   # unit + tests/ffi.rs
cargo build --release -p castellum-ffi --manifest-path native/Cargo.toml  # -> libcastellum_ffi.a

# macOS app (links the Rust staticlib)
bash apple/scripts/build-rust.sh                     # build staticlib (+universal if targets present)
xcodegen generate --spec apple/project.yml
xcodebuild -project apple/Castellum.xcodeproj -scheme Castellum \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# The app prints an FFI smoke line to stderr on launch, e.g.:
#   [castellum-smoke] core=0.1.0 open_rc=0 handle=1 close_rc=0 dir=/var/folders/.../castellum-smoke-...
```


## The C ABI (slice 1)

`native/crates/castellum-ffi/include/castellum.h` — four functions:
`castellum_version`, `castellum_string_free`, `castellum_open_profile`,
`castellum_close_profile`. Handles are opaque `u64` keys (0 = invalid). Rust owns
strings it returns — free them with `castellum_string_free`.

> **Note:** the header is **hand-written** for this small surface (offline-safe, no
> extra crates). A later slice may adopt `cbindgen` (via `build.rs`) once the exported
> surface grows richer types; if so, add a CI check that the committed header is fresh.

## Boundaries (do not cross)

- The FFI exposes small typed commands only — never provider objects, raw SQLite
  handles, IMAP sessions, AI clients, or Electron preload channel names.
- Rust owns durable state; Swift owns window/selection/presentation state.
- No Tantivy / llama.cpp / MLX / CoreML / Gmail API / Graph / JMAP until the core and
  macOS app are proven (see the decision log).
