#!/usr/bin/env bash
# Usage: run.sh <scenario>...  -> runs each via ui-check.sh --no-build, prints status + violations/step errors
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd
cd "$(git rev-parse --show-toplevel)" || exit 1
for s in "$@"; do scripts/ui-check.sh --no-build "$s" >/dev/null 2>&1; echo "== $s exit $?"
python3 - "$s" <<'PY'
import json,glob,sys
fs=sorted(glob.glob(f"build/ui-snapshots/{sys.argv[1]}/2*/report.json"))
r=json.load(open(fs[-1])); print("  ",r["status"],"last:",r.get("lastStep"),fs[-1].split("/")[-2])
for v in r.get("violations",[]): print("   V",v["rule"],v["window"],v["detail"][:230].replace("\n","\\n"))
for st in r["steps"]:
    if st["status"] not in("ok","violations"): print("   S",str(st)[:400])
PY
done
