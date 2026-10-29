#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

COMMON="$SANITIZER_FLAGS $DEBUG_FLAGS"
# Leak detection is off at build time (a linked hook), never at runtime.
export ASAN_OPTIONS=detect_leaks=0

# The compiler path cmake caches differs between the ccache-prefilled image build and a plain re-run
# (/opt/mayhem/ccache/bin/clang++ vs /usr/bin/clang++); cmake then drops its cache AND the -D
# options, so always configure from scratch.
rm -rf build/fuzz build/test

# 1) Sanitized Seastar library. The Fuzz build type (what upstream uses for its fuzzers) defines
#    SEASTAR_DEFAULT_ALLOCATOR so Seastar uses libc malloc and ASan's interceptors keep working. Only the `seastar` target is built here; the sstring harness is
#    compiled by hand below so the libFuzzer and standalone variants share one set of flags.
cmake -S . -B build/fuzz -G Ninja \
    -DCMAKE_BUILD_TYPE=Fuzz -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COMMON" -DCMAKE_CXX_FLAGS="$COMMON" \
    -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
    -DSeastar_SANITIZE=OFF -DSeastar_COMPRESS_DEBUG=OFF \
    -DSeastar_APPS=OFF -DSeastar_DEMOS=OFF -DSeastar_DOCS=OFF -DSeastar_TESTING=OFF \
    -DSeastar_INSTALL=OFF
cmake --build build/fuzz --target seastar -j"$MAYHEM_JOBS"

# 2) Harness: take the -std/-D/-I flags cmake used for the library's own sstring.cc so the harness
#    sees the same Seastar configuration (SEASTAR_SSTRING, API level, ...).
mapfile -t HARNESS_FLAGS < <(python3 - <<'PY'
import json, shlex
for e in json.load(open("build/fuzz/compile_commands.json")):
    if e["file"].endswith("src/core/sstring.cc"):
        for t in shlex.split(e["command"]):
            if t.startswith(("-D", "-I", "-std=")):
                print(t)
        break
PY
)
SEASTAR_LIBS=(build/fuzz/libseastar.a -lboost_program_options -lcares -lfmt -llz4 -ldl -latomic -lsctp
              -lprotobuf -lyaml-cpp -lhwloc -lgnutls -lssl -lcrypto -luring -llttng-ust -lpthread -lrt)

$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o build/lsan_off.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 "${HARNESS_FLAGS[@]}" -c tests/fuzz/sstring_fuzz.cc -o build/sstring_fuzz.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 "${HARNESS_FLAGS[@]}" -fsanitize=fuzzer-no-link -c tests/fuzz/sstring_fuzz.cc -o build/sstring_fuzz.fuzz.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE build/sstring_fuzz.fuzz.o build/lsan_off.o \
    "${SEASTAR_LIBS[@]}" -o /mayhem/sstring_fuzz
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS build/sstring_fuzz.o build/standalone_main.o build/lsan_off.o \
    "${SEASTAR_LIBS[@]}" -o /mayhem/sstring_fuzz-standalone

# 3) Test suite with the project's NORMAL flags (clean, independent build). Only the self-contained
#    Boost.Test unit tests (no reactor, no network, no privileges) are built; test.sh runs them.
TESTS=(sstring deleter defer shared_ptr circular_buffer chunked_fifo noncopyable_function packet simple_stream)
env -u CFLAGS -u CXXFLAGS -u LDFLAGS cmake -S . -B build/test -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
    -DSeastar_SANITIZE=OFF -DSeastar_APPS=ON -DSeastar_DEMOS=OFF -DSeastar_DOCS=OFF \
    -DSeastar_TESTING=ON -DSeastar_INSTALL=OFF
cmake --build build/test -j"$MAYHEM_JOBS" --target $(printf 'test_unit_%s ' "${TESTS[@]}")
