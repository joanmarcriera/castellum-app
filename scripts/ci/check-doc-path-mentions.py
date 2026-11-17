#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd
"""Fail when a living doc names a pre-move path in backticks (RP01).

Usage: python3 scripts/ci/check-doc-path-mentions.py
Checks a fixed list of (file, stale path) pairs that S23 moved into
project-docs/archive/electron/; frozen historical logs are not listed.
"""
import pathlib, sys

STALE = [
    ("project-docs/README.md", "`project-docs/" + "project-master-plan.md`"),
    ("project-docs/design/specs/2026-07-03-ai-job-queue-ollama-design.md",
     "`docs/" + "architecture-review/07-ai-architecture.md`"),
]
root = pathlib.Path(__file__).resolve().parents[2]
bad = [(f, s) for f, s in STALE if s in (root / f).read_text()]
for f, s in bad:
    print(f"{f}: stale path mention {s}")
sys.exit(1 if bad else 0)
