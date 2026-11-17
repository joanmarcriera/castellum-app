#!/usr/bin/env bash
# Castellum - S64 manual GUI launch probe (ADVISORY, not wired into CI — see
# project-docs/perf/read-path-budgets.md and DECISIONS.md's S64 entry).
#
# Launches the real ad-hoc Debug binary directly (bypassing xcodebuild test)
# against a fresh clone of the seeded 100k profile, with CASTELLUM_PERF_PROBE=1
# so AppModel.bootstrap() skips network/sync work and CastellumApp/
# MessageListView.Coordinator.apply print one `PERF gui_first_list
# measured=<ms>ms` line then call NSApp.terminate(nil). The timer starts at
# CastellumApp.init — dyld and the AppKit/Objective-C runtime start-up before
# that are NOT included, so this is a floor on the real cold-launch time, not
# the whole of it.
#
# Usage: scripts/perf/launch-probe.sh [runs=5]
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

runs="${1:-5}"
profile_dir="build/perf-profile-100k"

if [[ ! -f "$profile_dir/castellum.db" ]]; then
    echo "launch-probe: seeding $profile_dir (this is the one-off ~2-3 min idle cost, not part of any measurement)..."
    cargo run --release -p castellum-core --example seed_profile \
        --manifest-path native/Cargo.toml -- "$profile_dir"
fi

echo "launch-probe: building (ad-hoc Debug)..."
scripts/build-macos.sh build >/dev/null
app_path="$(scripts/build-macos.sh app-path)"
binary="$app_path/Contents/MacOS/Castellum"
[[ -x "$binary" ]] || { echo "launch-probe: no binary at $binary" >&2; exit 1; }

measurements=()
for i in $(seq 1 "$runs"); do
    clone_dir="$(mktemp -d)/perf-probe-$i"
    # `-c`: APFS clonefile when the source/dest are on the same volume —
    # O(1) regardless of the 100k profile's on-disk size (~180MB).
    cp -Rc "$profile_dir" "$clone_dir" 2>/dev/null || cp -R "$profile_dir" "$clone_dir"

    line="$(CASTELLUM_PROFILE_DIR="$clone_dir" CASTELLUM_PERF_PROBE=1 "$binary" 2>&1 \
        | grep '^PERF gui_first_list' || true)"
    rm -rf "$clone_dir"

    if [[ -z "$line" ]]; then
        echo "launch-probe: run $i produced no PERF line — skipped" >&2
        continue
    fi
    echo "run $i: $line"
    measurements+=("$(sed -n 's/.*measured=\([0-9.]*\)ms.*/\1/p' <<<"$line")")
done

if [[ ${#measurements[@]} -eq 0 ]]; then
    echo "launch-probe: no successful runs — nothing to report" >&2
    exit 1
fi

# Median over however many runs actually produced a PERF line.
median="$(printf '%s\n' "${measurements[@]}" | sort -n | awk '
    { a[NR] = $1 }
    END {
        n = NR
        if (n % 2 == 1) { print a[(n + 1) / 2] }
        else { print (a[n / 2] + a[n / 2 + 1]) / 2 }
    }')"
echo "launch-probe: median gui_first_list = ${median}ms over ${#measurements[@]} run(s) (advisory target 1500ms, no ceiling)"
