#!/usr/bin/env bash
# xe explorer wrapper: re-seed the xe-* GreenMail accounts (deterministic start), run one
# scenario with --no-build, then print the server truth (folders + flags) for comparison.
# Usage: build/explore/xe/run.sh <scenario-name> [more ui-check args]
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT" || exit 2
python3 build/explore/xe/seed.py reset || exit 2
scripts/ui-check.sh --no-build "$@"; rc=$?
echo "--- server after run (rc=$rc)"
python3 build/explore/xe/seed.py dump xe-r1@local.test xe-r2@local.test
exit $rc
