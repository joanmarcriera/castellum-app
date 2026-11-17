#!/usr/bin/env bash
# trend.sh - compare a new perf run against the stored history.
#
# Usage:
#   scripts/perf/trend.sh HISTORY.jsonl NEW.jsonl
#   scripts/perf/trend.sh --self-test
#
# Both files are the JSONL written by the perf gates when CASTELLUM_PERF_JSONL
# is set (one object per row: name, measured, unit, target, ceiling, verdict,
# sha, runner, load1, ts). For every row of NEW it takes the HISTORY rows with
# the same name AND the same runner (a Mac number is never compared with a
# Linux one), keeps the last 20 in file order, and prints the delta against
# their median.
#
# Exit status: 1 when any row is slower than that median by more than
# PERF_TREND_PCT percent (default 25) AND by more than PERF_TREND_MIN_ABS ms
# (default 0.5), the floor applying ONLY to rows whose unit is "ms" (ratio and
# KiB rows keep the pure percentage rule): a
# sub-millisecond row jumping 0.1 -> 0.2 ms is +100% but pure noise, so the
# absolute floor stops it flaking. Else 0. A row with fewer than 5 history
# runs prints "insufficient history" and can never fail. A missing HISTORY
# file counts as empty. Lower is better for every perf row (ms, KiB, ratios).
#
# A regressing run is NOT appended to history: in CI the compare step fails
# the job, the later "Append to history (main only)" step is skipped, so a bad
# main run never drags the median up and hides itself on the next run. Once the
# regression is fixed (or the baseline is deliberately reset) the next green
# main run appends as usual. This is intended; see project-docs/perf/
# read-path-budgets.md "Trend lane".
#
# Plain awk only (no jq: the Linux CI runner container is a bare ubuntu image).
# The rows are compact serde_json output, so fields are pulled by pattern.
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd

set -euo pipefail

WINDOW=20
MIN_RUNS=5

trend() {
  local history="$1" new="$2"
  [ -f "$new" ] || { echo "trend.sh: no such file: $new" >&2; return 2; }
  [ -f "$history" ] || history=/dev/null
  awk -v hist_file="$history" -v pct="${PERF_TREND_PCT:-25}" -v minabs="${PERF_TREND_MIN_ABS:-0.5}" -v window="$WINDOW" -v minruns="$MIN_RUNS" '
    function str(line, key,   m) {
      if (match(line, "\"" key "\":\"[^\"]*\"")) {
        m = substr(line, RSTART, RLENGTH)
        sub("^\"" key "\":\"", "", m); sub("\"$", "", m); return m
      }
      return ""
    }
    function num(line, key,   m) {
      if (match(line, "\"" key "\":-?[0-9.eE+-]+")) {
        m = substr(line, RSTART, RLENGTH); sub("^\"" key "\":", "", m); return m + 0
      }
      return ""
    }
    # Insertion sort of arr[1..n]; n is at most `window`.
    function median(arr, n,   i, j, t, a) {
      for (i = 1; i <= n; i++) a[i] = arr[i]
      for (i = 2; i <= n; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j+1] = a[j]; a[j+1] = t }
      return (n % 2) ? a[(n+1)/2] : (a[n/2] + a[n/2+1]) / 2
    }
    # History vs new run is decided by file name, not FNR == NR: an empty or
    # missing history would otherwise make the new file look like history.
    FILENAME == hist_file {           # first file: history
      n = str($0, "name"); r = str($0, "runner"); m = num($0, "measured")
      if (n == "" || m == "") next
      k = r SUBSEP n; cnt[k]++; hist[k, cnt[k]] = m
      next
    }
    {                                  # second file: the new run
      n = str($0, "name"); r = str($0, "runner"); m = num($0, "measured")
      if (n == "" || m == "") next
      k = r SUBSEP n; c = cnt[k] + 0
      if (c < minruns) {
        printf "%-62s %-8s %12.3f  insufficient history (%d run%s)\n", n, r, m, c, (c == 1 ? "" : "s")
        next
      }
      start = (c > window) ? c - window + 1 : 1; w = 0
      for (i = start; i <= c; i++) vals[++w] = hist[k, i]
      med = median(vals, w); delete vals
      if (med <= 0) { printf "%-62s %-8s %12.3f  median %.3f, delta n/a\n", n, r, m, med; next }
      d = (m - med) / med * 100
      verdict = "ok"
      if (d > pct && (str($0, "unit") != "ms" || (m - med) > minabs)) { verdict = "REGRESSION"; bad++ }
      printf "%-62s %-8s %12.3f  median %.3f (%d runs)  %+.1f%%  %s\n", n, r, m, med, w, d, verdict
    }
    END {
      if (bad) { printf "trend: %d row(s) slower than the median by more than %s%% (and %s ms for ms rows)\n", bad, pct, minabs; exit 1 }
    }
  ' "$history" "$new"
}

self_test() {
  local dir fails=0 out rc
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tests"
  expect() { # case, expected exit, expected output fragment
    set +e; out="$(trend "$dir/$1.history.jsonl" "$dir/$1.new.jsonl")"; rc=$?; set -e
    if [ "$rc" -eq "$2" ] && grep -q -- "$3" <<<"$out"; then
      echo "ok   $1 (exit $rc, saw '$3')"
    else
      echo "FAIL $1: exit $rc (want $2), want '$3' in:"; echo "$out"; fails=$((fails+1))
    fi
  }
  expect regression   1 "REGRESSION"
  expect noise        0 "ok"
  expect subms        0 "ok"
  expect ratio        1 "REGRESSION"   # the absolute floor is ms-only
  expect insufficient 0 "insufficient history"
  # Zero history: an empty file and a missing file must both say so per row.
  : >"$dir/../.empty.$$"
  for h in "$dir/../.empty.$$" "$dir/does-not-exist.jsonl"; do
    set +e; out="$(trend "$h" "$dir/noise.new.jsonl")"; rc=$?; set -e
    if [ "$rc" -eq 0 ] && grep -q "insufficient history (0 runs)" <<<"$out"; then echo "ok   zero history (exit 0)"
    else echo "FAIL zero history: exit $rc, output: $out"; fails=$((fails+1)); fi
  done
  rm -f "$dir/../.empty.$$"
  # A noise run must not mention a regression, and the regression run must
  # leave the in-budget row alone.
  set +e; out="$(trend "$dir/noise.history.jsonl" "$dir/noise.new.jsonl")"; set -e
  if grep -q REGRESSION <<<"$out"; then echo "FAIL noise printed REGRESSION"; fails=$((fails+1)); fi
  # The floor is what keeps subms quiet: with it at 0 the +100% row fails.
  set +e; PERF_TREND_MIN_ABS=0 trend "$dir/subms.history.jsonl" "$dir/subms.new.jsonl" >/dev/null; rc=$?; set -e
  if [ "$rc" -eq 1 ]; then echo "ok   PERF_TREND_MIN_ABS=0 flags the sub-ms row"; else echo "FAIL PERF_TREND_MIN_ABS ignored (exit $rc)"; fails=$((fails+1)); fi
  # Tightening the threshold turns the noise case into a failure: PERF_TREND_PCT is honoured.
  set +e; PERF_TREND_PCT=5 trend "$dir/noise.history.jsonl" "$dir/noise.new.jsonl" >/dev/null; rc=$?; set -e
  if [ "$rc" -eq 1 ]; then echo "ok   PERF_TREND_PCT=5 flags the 12% noise row"; else echo "FAIL PERF_TREND_PCT ignored (exit $rc)"; fails=$((fails+1)); fi
  [ "$fails" -eq 0 ] && echo "self-test passed" || { echo "self-test FAILED ($fails)"; return 1; }
}

case "${1:-}" in
  --self-test) self_test ;;
  -h|--help|"") sed -n '2,32p' "$0"; [ -n "${1:-}" ] || exit 2 ;;
  *) [ $# -eq 2 ] || { echo "usage: trend.sh HISTORY.jsonl NEW.jsonl | --self-test" >&2; exit 2; }
     trend "$1" "$2" ;;
esac
