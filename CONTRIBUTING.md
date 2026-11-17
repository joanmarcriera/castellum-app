# Contributing to Castellum

Thanks for looking. Castellum is a pre-1.0 native macOS email client (Rust core, Swift/AppKit UI),
maintained by one person in spare time, so small, focused contributions are the easiest to review.

## Where help is most useful

- **Testing** against real mail providers and reporting what breaks (see "Reporting bugs").
- **Rust and Swift contributions**: bug fixes, tests, and performance work in the sync core and the UI.
- **Provider presets** (IMAP/SMTP settings and quirks for a provider you actually use).

Please open an issue before starting anything larger than a bug fix, so we can agree on scope first.

## Reporting bugs and ideas

Use the issue templates under "New issue". Include your macOS version, the Castellum version or
commit, and the provider involved. **Never paste real mail, addresses or credentials**; redact first.
Security problems do not go in public issues: see [SECURITY.md](SECURITY.md).

## Build and test

Prerequisites: Rust (`rustup`), Xcode with command line tools, `xcodegen` (`brew install xcodegen`),
and optionally Docker for the GreenMail IMAP/SMTP test server.

```bash
# Rust core
cargo fmt --all --check --manifest-path native/Cargo.toml
cargo clippy --all-targets --manifest-path native/Cargo.toml -- -D warnings
cargo test --manifest-path native/Cargo.toml

# macOS app (builds the Rust staticlib, generates the Xcode project, runs xcodebuild)
scripts/build-macos.sh test        # unit tests, unsigned
scripts/build-macos.sh build       # ad-hoc signed Debug app

# End-to-end tests against a local mail server
docker-compose -f scripts/local-imap/docker-compose.yml up -d
npm install --no-save --prefix scripts/local-imap imap mailparser nodemailer   # once: seed-script deps
node scripts/local-imap/seed-greenmail.js --count 20
```

`fmt --check` and `clippy -D warnings` must pass for Rust changes. Details: `native/README.md`.

## Conventions

- **Conventional Commits**: `type(scope): summary`, with `feat`, `fix`, `docs`, `refactor`, `perf`,
  `test`, `chore` or `ci`. The changelog is generated from commit messages with
  [git-cliff](https://git-cliff.org) (`cliff.toml`), so write them for a reader.
- **One logical change per commit and per pull request.** Add or update a test with every fix.
- **Rust owns durable state across the C ABI; Swift owns presentation.** Do not expose provider
  objects, SQL handles or IMAP sessions across the boundary. The header
  `native/crates/castellum-ffi/include/castellum.h` is hand-written; update it with the Rust side.
- **Synthetic data only** in tests, fixtures, screenshots and docs.
- New source files carry the two-line header (older files without one are covered by `LICENSE`):
  `SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0` and `Copyright <year> Riera Technologies Ltd`.

## Sign-off (Developer Certificate of Origin)

Sign every commit with `git commit -s`, which appends:

```
Signed-off-by: Your Name <you@example.com>
```

By signing off you certify the [Developer Certificate of Origin 1.1](https://developercertificate.org/):
you wrote the change or have the right to submit it.

**Licence of contributions.** Castellum is published under the noncommercial licence in
[LICENSE](LICENSE) and is also licensed commercially by Riera Technologies Ltd (see
[COMMERCIAL.md](COMMERCIAL.md)). So that both can include your change, you submit it under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) (inbound), and it is then
distributed here under LICENSE (outbound). If you cannot agree to that, open an issue instead of a
pull request.

## Pull requests

1. Fork, branch from `main`, keep the branch focused.
2. Run the Rust checks above (and the Swift tests if you touched `apple/`).
3. Fill in the pull request template. Describe what changed and how you verified it.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
