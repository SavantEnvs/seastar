#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Seastar's self-contained Boost.Test unit tests, built by mayhem/build.sh into build/test.
# Each binary asserts known values (sstring, deleter, shared_ptr, containers, packets, streams, ...).
TESTS=(sstring deleter defer shared_ptr circular_buffer chunked_fifo noncopyable_function packet simple_stream)
passed=0 failed=0
for t in "${TESTS[@]}"; do
  bin="$SRC/build/test/tests/unit/${t}_test"
  if [ ! -x "$bin" ]; then echo "missing test runner $bin (build.sh bug)" >&2; failed=$((failed + 1)); continue; fi
  out=$(timeout 900 "$bin" --report_level=short 2>&1); rc=$?
  echo "$out" | tail -5
  # Boost.Test summary: "N test cases out of M passed" or "N test cases out of M failed".
  line=$(echo "$out" | grep -E '[0-9]+ test cases out of [0-9]+ (passed|failed)' | tail -1)
  if [ -z "$line" ]; then
    echo "FAIL $t: no Boost.Test summary (rc=$rc)" >&2; failed=$((failed + 1)); continue
  fi
  n=$(echo "$line" | sed -E 's/^ *([0-9]+) test cases out of ([0-9]+) (passed|failed).*/\1/')
  m=$(echo "$line" | sed -E 's/^ *([0-9]+) test cases out of ([0-9]+) (passed|failed).*/\2/')
  if echo "$line" | grep -q 'passed' && [ "$rc" -eq 0 ] && [ "$n" -eq "$m" ] && [ "$m" -gt 0 ]; then
    passed=$((passed + m))
  else
    # failed line: N failed out of M; a passed line with rc!=0 counts the whole binary as failed
    if echo "$line" | grep -q 'failed'; then passed=$((passed + m - n)); failed=$((failed + n)); else failed=$((failed + 1)); fi
  fi
done

emit_ctrf "boost-test" "$passed" "$failed" 0
