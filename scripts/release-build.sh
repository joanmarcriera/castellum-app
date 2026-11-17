#!/usr/bin/env bash
# release-build.sh — build the distributable Castellum DMG (universal arm64 + x86_64).
# The GitHub release workflow runs exactly this script; run it locally to reproduce a release.
#
# Usage: scripts/release-build.sh --version X.Y.Z[-pre] [--out DIR]
#   --version  marketing version stamped into the app (CFBundleShortVersionString)
#   --out      output directory (default: dist/). Holds the .app, the DMG and SHA256SUMS.
#
# Signing is chosen from the environment, never from the repository:
#   * Developer ID mode: APPLE_TEAM_ID is set AND the keychain search list holds a
#     "Developer ID Application" identity for that team. The app and the DMG are signed
#     with the hardened runtime and a secure timestamp.
#     If APPLE_API_KEY_PATH, APPLE_API_KEY_ID and APPLE_API_ISSUER are also set, both
#     are notarised and stapled, and the stable alias Castellum.dmg is written too.
#   * Otherwise: ad-hoc mode. The app is ad-hoc signed ("-"), NOT notarised, and the
#     DMG is named Castellum-<version>-unsigned.dmg. Gatekeeper blocks it on first open
#     (see README, "Opening an unsigned build"). The App Group needs a Team ID, so the
#     Share Extension handoff is off in this mode.
#
# Exit: 0 built and verified · 1 build or verification failed · 2 usage error.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd
set -euo pipefail

usage() { sed -n '2,21p' "$0"; exit "${1:-2}"; }
version="" out="dist"
while (($#)); do
  case "$1" in
    --version) version=${2:?--version needs a value}; shift 2 ;;
    --out) out=${2:?--out needs a directory}; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "release-build: unknown argument: $1" >&2; usage 2 ;;
  esac
done
[[ -n "$version" ]] || { echo "release-build: --version is required" >&2; usage 2; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
  || { echo "release-build: version '$version' is not X.Y.Z or X.Y.Z-pre" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
derived="$ROOT/build/DerivedData.release.noindex"

# --- choose the signing mode -------------------------------------------------
mode=adhoc identity=""
if [[ -n "${APPLE_TEAM_ID:-}" ]]; then
  # Resolve by hash: a name is a substring match and goes "ambiguous" with two identities.
  identity="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "($APPLE_TEAM_ID)" | head -1 | awk '{print $2}' || true)"
  if [[ -n "$identity" ]]; then mode=developer-id; else
    echo "release-build: APPLE_TEAM_ID is set but no Developer ID Application identity for it; building ad-hoc" >&2
  fi
fi
notarise=0
if [[ "$mode" == developer-id && -n "${APPLE_API_KEY_PATH:-}" && -n "${APPLE_API_KEY_ID:-}" && -n "${APPLE_API_ISSUER:-}" ]]; then
  notarise=1
fi
echo "release-build: version $version, mode $mode, notarise $notarise, out $out"

# --- build ---------------------------------------------------------------------
bash apple/scripts/build-rust.sh --universal
xcodegen generate --quiet --spec apple/project.yml

common=(-project apple/Castellum.xcodeproj -scheme Castellum -configuration Release
        -derivedDataPath "$derived" MARKETING_VERSION="$version")
rm -rf "$out/Castellum.app"
if [[ "$mode" == developer-id ]]; then
  xcodebuild archive "${common[@]}" -archivePath "$ROOT/build/Castellum.xcarchive" \
    DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
  sed "s/__APPLE_TEAM_ID__/$APPLE_TEAM_ID/" apple/configs/ExportOptions-Direct.plist \
    > "$ROOT/build/ExportOptions.plist"
  rm -rf "$ROOT/build/export"
  xcodebuild -exportArchive -archivePath "$ROOT/build/Castellum.xcarchive" \
    -exportOptionsPlist "$ROOT/build/ExportOptions.plist" -exportPath "$ROOT/build/export"
  ditto "$ROOT/build/export/Castellum.app" "$out/Castellum.app"
else
  # Command-line settings outrank DirectRelease.xcconfig: ad-hoc identity, no team, and no
  # --timestamp (a secure timestamp needs a real identity).
  xcodebuild build "${common[@]}" -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS= CODE_SIGN_STYLE=Manual
  ditto "$derived/Build/Products/Release/Castellum.app" "$out/Castellum.app"
fi
app="$out/Castellum.app"

# --- notarise the app ----------------------------------------------------------
notary=()
if ((notarise)); then
  notary=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
  ditto -c -k --keepParent "$app" "$out/Castellum-notarise.zip"
  xcrun notarytool submit "$out/Castellum-notarise.zip" "${notary[@]}" --wait
  rm -f "$out/Castellum-notarise.zip"
  xcrun stapler staple "$app"
fi

# --- DMG -----------------------------------------------------------------------
if [[ "$mode" == developer-id ]]; then dmg="$out/Castellum-$version.dmg"; else dmg="$out/Castellum-$version-unsigned.dmg"; fi
bash apple/scripts/make-dmg.sh "$app" "$dmg"
if [[ "$mode" == developer-id ]]; then
  codesign --sign "$identity" --timestamp "$dmg"
  if ((notarise)); then
    xcrun notarytool submit "$dmg" "${notary[@]}" --wait
    xcrun stapler staple "$dmg"
  fi
fi

# --- verify --------------------------------------------------------------------
archs="$(lipo -archs "$app/Contents/MacOS/Castellum")"
for want in arm64 x86_64; do
  grep -qw "$want" <<<"$archs" || { echo "release-build: binary is missing $want (got: $archs)" >&2; exit 1; }
done
got_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$got_version" == "$version" ]] || { echo "release-build: app says $got_version, expected $version" >&2; exit 1; }
codesign --verify --strict --deep --verbose=2 "$app"
if ((notarise)); then
  bash apple/scripts/verify-release.sh "$app" "$dmg"
  cp "$dmg" "$out/Castellum.dmg"           # stable name, only ever for a notarised build
  xcrun stapler validate "$out/Castellum.dmg"
fi

# --- checksums and build record -----------------------------------------------
(cd "$out" && shasum -a 256 ./*.dmg | sed 's| \./| |' > "Castellum-$version-SHA256SUMS.txt")
{
  echo "version=$version"
  echo "mode=$mode"
  echo "notarised=$notarise"
  echo "archs=$archs"
  echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "xcode=$(xcodebuild -version | head -1)"
  echo "rustc=$(rustc --version)"
} > "$out/build-info.txt"
cat "$out/Castellum-$version-SHA256SUMS.txt" "$out/build-info.txt"
echo "release-build: done"
