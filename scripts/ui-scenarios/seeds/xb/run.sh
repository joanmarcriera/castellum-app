#!/usr/bin/env bash
# Usage: run.sh <tag> <scenario>...  — runs each scenario with --no-build sequentially; one summary block per scenario in build/explore/xb/logs/<scenario>.<tag>.log
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../../.."; tag="$1"; shift; mkdir -p "$here/logs"
for s in "$@"; do (cd "$root" && scripts/ui-check.sh --no-build "$s" > "$here/logs/$s.$tag.log" 2>&1; echo "exit=$?" >> "$here/logs/$s.$tag.log"); done
