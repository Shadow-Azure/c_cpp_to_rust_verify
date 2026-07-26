#!/usr/bin/env bash
# eval-equivalence.sh — evaluate functional equivalence between the Rust
# port and the original C implementation using a TWO-BINARY comparison.
#
# Model: the test driver (ffi-compare/compare_tests.c) calls the public
# FlashDB C API by its ORIGINAL symbol names (fdb_kvdb_init, fdb_kv_set,
# fdb_calc_crc32, fdb_tsl_append, ...). The harness compiles this single
# driver twice — once linked against the C reference static library, once
# against the Rust static library (whose ffi.rs must export the SAME
# #[no_mangle] extern "C" symbols as flashdb.h). Each binary is run with
# identical inputs; their structured CASE-line stdout is diffed line by line.
# Matching CASE lines count as PASSED, differing/missing lines as FAILED.
#
# Because each binary contains exactly ONE library there is no symbol
# collision, so the Rust exports need NO project-specific prefix (the old
# fdb_rust_* namespacing is removed). This matches the standard contract for
# a C→Rust migration: the Rust crate is a drop-in for the C library.
#
# Scoring semantics are unchanged: equivalence score = passed / total and
# pass requires FAILED == 0. The eval-config.json weight (0.25) is unchanged.
#
# Output: JSON to stdout (consumed by aggregate-score.py / loopengine.eval).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$ROOT_DIR/rust-flashdb"
FFI_DIR="$ROOT_DIR/ffi-test"  # 预置的 FFI 测试基础设施
FFI_RS="$RUST_DIR/src/ffi.rs"
C_API_H="$ROOT_DIR/flashdb/inc/flashdb.h"
DRIVER_C="$FFI_DIR/compare_tests.c"

# ============================================================
# 1. API coverage analysis
#
# The expected contract is now "the Rust FFI exports the SAME symbols the C
# library exposes in flashdb.h", under their original names. We derive the
# expected public-API function set dynamically from the C header (no hardcoded
# list) and check ffi.rs declares each as a #[no_mangle] extern "C" export.
# ============================================================

# Derive expected public function names from the C header.
# Only match function declarations (with '(' after name), excluding type
# definitions like fdb_kv_t, fdb_err_t, etc.
EXPECTED_FUNCS=""
if [ -f "$C_API_H" ]; then
  EXPECTED_FUNCS=$(grep -oE '\bfdb_[a-z0-9_]+[[:space:]]*\(' "$C_API_H" \
    | sed 's/[[:space:]]*($//' | sort -u)
fi
EXPECTED_COUNT=$(echo "$EXPECTED_FUNCS" | grep -c . || true)

# From ffi.rs extract which pub use exports are present.
# Only match the actual function name (last fdb_* token before ';'),
# excluding module names like fdb_kvdb, fdb_tsdb, etc.
IMPLEMENTED_FUNCS=""
if [ -f "$FFI_RS" ]; then
  IMPLEMENTED_FUNCS=$(grep 'pub use.*fdb_' "$FFI_RS" \
    | sed 's/.*:://' | sed 's/;//' \
    | grep -oE '\bfdb_[a-z0-9_]+' | sort -u)
fi
IMPLEMENTED_COUNT=$(echo "$IMPLEMENTED_FUNCS" | grep -c . || true)

# Per-category expected/implemented counts, derived from function names only.
CRC_EXPECTED=$(echo "$EXPECTED_FUNCS"    | grep -c "crc32" || true)
CRC_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -c "crc32" || true)
KV_EXPECTED=$(echo "$EXPECTED_FUNCS"    | grep -cE "kvdb|kv_" || true)
KV_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -cE "kvdb|kv_" || true)
TS_EXPECTED=$(echo "$EXPECTED_FUNCS"    | grep -cE "tsdb|tsl_" || true)
TS_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -cE "tsdb|tsl_" || true)

# ============================================================
# Preconditions
# ============================================================

if [ ! -f "$FFI_RS" ]; then
  printf '{"pass": false, "ffi_present": false, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": 0, "crc32": {"expected": %d, "implemented": 0}, "kvdb": {"expected": %d, "implemented": 0}, "tsdb": {"expected": %d, "implemented": 0}}, "message": "ffi.rs not found"}\n' \
    "$EXPECTED_COUNT" "$CRC_EXPECTED" "$KV_EXPECTED" "$TS_EXPECTED"
  exit 0
fi

if [ ! -d "$RUST_DIR" ] || [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d, "crc32": {"expected": %d, "implemented": %d}, "kvdb": {"expected": %d, "implemented": %d}, "tsdb": {"expected": %d, "implemented": %d}}, "message": "rust-flashdb/ not found"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$CRC_EXPECTED" "$CRC_IMPLEMENTED" "$KV_EXPECTED" "$KV_IMPLEMENTED" "$TS_EXPECTED" "$TS_IMPLEMENTED"
  exit 0
fi

if [ ! -f "$DRIVER_C" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "message": "ffi-test/compare_tests.c not found (should be pre-built in repo)"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT"
  exit 0
fi

if [ ! -f "$FFI_DIR/Makefile" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "message": "ffi-test/Makefile not found (should be pre-built in repo)"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT"
  exit 0
fi

# ============================================================
# 2. Build the C reference static library
# ============================================================

cd "$FFI_DIR"
rm -rf build

if ! make c-lib >/tmp/equiv-c-build.log 2>&1; then
  # Capture error details (first 500 chars)
  C_BUILD_ERROR=$(head -c 500 /tmp/equiv-c-build.log 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "c_build_error": "%s", "message": "C library build failed (see equiv-detail.log)"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$C_BUILD_ERROR"
  # Copy build log to detail log for artifact upload
  cp /tmp/equiv-c-build.log /tmp/equiv-detail.log 2>/dev/null || true
  exit 0
fi

# ============================================================
# 3. Build the Rust static library
# ============================================================

cd "$RUST_DIR"
RUST_BUILD_OK=false
RUST_ERROR=""

if timeout 600 cargo build --release >/tmp/equiv-rust-build.log 2>&1; then
  # Detect package name from Cargo.toml
  PACKAGE_NAME=$(grep '^name' Cargo.toml 2>/dev/null | head -1 | sed 's/.*= *"\(.*\)"/\1/')
  if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME="flashdb"  # fallback
  fi

  RUST_LIB=""
  for lib in "target/release/lib${PACKAGE_NAME}.a" "target/release/lib${PACKAGE_NAME}.rlib" \
             "target/release/libflashdb.a" "target/release/libflashdb.rlib"; do
    if [ -f "$lib" ]; then
      RUST_LIB="$lib"
      break
    fi
  done
  if [ -n "$RUST_LIB" ]; then
    cp "$RUST_LIB" "$FFI_DIR/build/libflashdb_rust.a"
    RUST_BUILD_OK=true
  else
    RUST_ERROR="Rust library file not found after build (searched: lib${PACKAGE_NAME}.a, libflashdb.a)"
  fi
else
  RUST_ERROR=$(head -5 /tmp/equiv-rust-build.log 2>/dev/null | tr '\n' ' ' | head -c 200)
fi

if [ "$RUST_BUILD_OK" = false ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d, "crc32": {"expected": %d, "implemented": %d}, "kvdb": {"expected": %d, "implemented": %d}, "tsdb": {"expected": %d, "implemented": %d}}, "rust_build_error": "%s", "message": "Rust library build failed"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$CRC_EXPECTED" "$CRC_IMPLEMENTED" "$KV_EXPECTED" "$KV_IMPLEMENTED" "$TS_EXPECTED" "$TS_IMPLEMENTED" "$RUST_ERROR"
  exit 0
fi

# ============================================================
# 4. Compile the SAME driver twice — once per library
#
# compare_c   : compare_tests.c + libflashdb_c.a    (C reference)
# compare_rust: compare_tests.c + libflashdb_rust.a (Rust port)
#
# No symbol collision: each binary links exactly one implementation.
#
# We use the Makefile targets (make compare-c / make compare-rust) instead
# of raw `eval cc` to ensure identical compiler flags between the C library
# build (step 2) and the driver build. The `eval` + shell-quoting approach
# was fragile and caused compilation failures on GCC (Ubuntu 24.04).
# ============================================================

cd "$FFI_DIR"

# C-reference binary — use the Makefile's compare-c target which reuses the
# same CFLAGS, include paths, and LDFLAGS as the c-lib build above.
if ! make compare-c >/tmp/equiv-compile-c.log 2>&1; then
  LINK_ERROR=$(head -5 /tmp/equiv-compile-c.log 2>/dev/null | tr '\n' ' ' | head -c 300)
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "link_error": "%s", "message": "compare_c (C reference) link failed"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$LINK_ERROR"
  exit 0
fi

# Rust-port binary — build/ was cleaned earlier so make compare-rust will
# see the prerequisite (build/libflashdb_rust.a) copied in step 3 and only
# recompile the driver, not re-invoke cargo.
if ! make compare-rust >/tmp/equiv-compile-rust.log 2>&1; then
  LINK_ERROR=$(head -5 /tmp/equiv-compile-rust.log 2>/dev/null | tr '\n' ' ' | head -c 300)
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "link_error": "%s", "message": "compare_rust link failed (Rust FFI symbols do not match flashdb.h)"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$LINK_ERROR"
  exit 0
fi

# ============================================================
# 5. Run both binaries, capture deterministic CASE-line stdout
# ============================================================

timeout 300 build/compare_c    >/tmp/equiv-c-out.txt    2>/tmp/equiv-c-stderr.log    || true
timeout 300 build/compare_rust >/tmp/equiv-rust-out.txt 2>/tmp/equiv-rust-stderr.log || true

# Sort lines so order-independent; each CASE line is a self-contained atomic
# observation identified by "CASE <id> <key>". Identical value => equivalent.
LC_ALL=C sort /tmp/equiv-c-out.txt   -o /tmp/equiv-c-out.sorted
LC_ALL=C sort /tmp/equiv-rust-out.txt -o /tmp/equiv-rust-out.sorted

# Lines present in both => PASS. Lines missing from either => FAIL.
LC_ALL=C comm -12 /tmp/equiv-c-out.sorted /tmp/equiv-rust-out.sorted > /tmp/equiv-match.txt
LC_ALL=C comm -23 /tmp/equiv-c-out.sorted /tmp/equiv-rust-out.sorted > /tmp/equiv-only-c.txt
LC_ALL=C comm -13 /tmp/equiv-c-out.sorted /tmp/equiv-rust-out.sorted > /tmp/equiv-only-rust.txt

# ============================================================
# 6. Build a synthetic TEST_OUTPUT in the legacy text format so the
#    unchanged parsing/decision/JSON block below computes scores.
#
#    Format (one observation per line):
#      <case_id> PASS | <case_id> FAIL
#    plus the summary line:
#      PASSED: N  FAILED: N  TOTAL: N
#
#    The case_id is the 3rd whitespace-delimited token of a CASE line
#    (e.g. "kv_set_get_string" from "CASE <category> kv_set_get_string PASS").
#    Field 3 is the test_name which carries the crc32/kv_/tsl_/ts_ prefix
#    the per-category greps rely on.
# ============================================================

TEST_OUTPUT=""

# matched lines -> PASS, labelled by case id
while IFS= read -r line; do
  [ -z "$line" ] && continue
  cid=$(printf '%s' "$line" | awk '{print $3}')
  [ -z "$cid" ] && continue
  TEST_OUTPUT="${TEST_OUTPUT}${cid} PASS"$'\n'
done < /tmp/equiv-match.txt

# C-only lines -> FAIL (Rust produced no such observation / different value)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  cid=$(printf '%s' "$line" | awk '{print $3}')
  [ -z "$cid" ] && continue
  TEST_OUTPUT="${TEST_OUTPUT}${cid} FAIL"$'\n'
done < /tmp/equiv-only-c.txt

# Rust-only lines -> FAIL
while IFS= read -r line; do
  [ -z "$line" ] && continue
  cid=$(printf '%s' "$line" | awk '{print $3}')
  [ -z "$cid" ] && continue
  TEST_OUTPUT="${TEST_OUTPUT}${cid} FAIL"$'\n'
done < /tmp/equiv-only-rust.txt

# Summary counts
CASE_TOTAL=$(printf '%s' "$TEST_OUTPUT" | grep -c . || true)
CASE_PASSED=$(printf '%s' "$TEST_OUTPUT" | grep -c "PASS" || true)
CASE_FAILED=$(printf '%s' "$TEST_OUTPUT" | grep -c "FAIL" || true)
TEST_OUTPUT="${TEST_OUTPUT}PASSED: ${CASE_PASSED}  FAILED: ${CASE_FAILED}  TOTAL: ${CASE_TOTAL}"$'\n'

# ============================================================
# 7. Parse the synthetic TEST_OUTPUT (unchanged scoring logic)
# ============================================================

# 解析 PASS/FAIL 统计
PASSED=$(echo "$TEST_OUTPUT" | sed -n 's/.*PASSED: \([0-9]*\).*/\1/p' | head -1)
FAILED=$(echo "$TEST_OUTPUT" | sed -n 's/.*FAILED: \([0-9]*\).*/\1/p' | head -1)
TOTAL=$(echo "$TEST_OUTPUT" | sed -n 's/.*TOTAL: \([0-9]*\).*/\1/p' | head -1)

PASSED=${PASSED:-0}
FAILED=${FAILED:-0}
TOTAL=${TOTAL:-0}

# 解析各类别通过数
CRC_PASS=$(echo "$TEST_OUTPUT" | grep -c "crc32.*PASS" || true)
CRC_FAIL=$(echo "$TEST_OUTPUT" | grep -c "crc32.*FAIL" || true)
KV_PASS=$(echo "$TEST_OUTPUT" | grep -c "kv_.*PASS" || true)
KV_FAIL=$(echo "$TEST_OUTPUT" | grep -c "kv_.*FAIL" || true)
TS_PASS=$(echo "$TEST_OUTPUT" | grep -c "tsl_.*PASS\|ts_.*PASS" || true)
TS_FAIL=$(echo "$TEST_OUTPUT" | grep -c "tsl_.*FAIL\|ts_.*FAIL" || true)

# 判断是否通过
PASS="false"
if [ "$TOTAL" -gt 0 ] && [ "$FAILED" -eq 0 ]; then
  PASS="true"
fi

# ============================================================
# 8. Output JSON (clean format via printf)
# ============================================================

printf '{\n'
printf '  "pass": %s,\n' "$PASS"
printf '  "ffi_present": true,\n'
printf '  "passed": %d,\n' "$PASSED"
printf '  "failed": %d,\n' "$FAILED"
printf '  "total": %d,\n' "$TOTAL"
printf '  "api_coverage": {\n'
printf '    "expected": %d,\n' "$EXPECTED_COUNT"
printf '    "implemented": %d,\n' "$IMPLEMENTED_COUNT"
printf '    "crc32": {"expected": %d, "implemented": %d},\n' "$CRC_EXPECTED" "$CRC_IMPLEMENTED"
printf '    "kvdb": {"expected": %d, "implemented": %d},\n' "$KV_EXPECTED" "$KV_IMPLEMENTED"
printf '    "tsdb": {"expected": %d, "implemented": %d}\n' "$TS_EXPECTED" "$TS_IMPLEMENTED"
printf '  },\n'
printf '  "details": {\n'
printf '    "crc32": {"passed": %d, "failed": %d},\n' "$CRC_PASS" "$CRC_FAIL"
printf '    "kvdb": {"passed": %d, "failed": %d},\n' "$KV_PASS" "$KV_FAIL"
printf '    "tsdb": {"passed": %d, "failed": %d}\n' "$TS_PASS" "$TS_FAIL"
printf '  }\n'
printf '}\n'

# Emit detail diff to stderr when there are mismatches (observability only;
# does not change pass/fail scoring).
if [ "$FAILED" -gt 0 ]; then
  echo "--- Equivalence diff (C vs Rust) ---" >&2
  echo "[only in C reference output]:" >&2
  cat /tmp/equiv-only-c.txt >&2
  echo "[only in Rust output]:" >&2
  cat /tmp/equiv-only-rust.txt >&2
fi

exit 0
