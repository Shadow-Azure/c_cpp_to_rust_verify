#!/usr/bin/env bash
# equivalence.sh — evaluate functional equivalence between the Rust
# port and the original C libuv using a TWO-BINARY comparison.
#
# Model: the test driver (libuv/ffi-test/compare_tests.c) calls the
# public libuv C API by its ORIGINAL symbol names (uv_loop_init,
# uv_timer_start, uv_strerror, ...). The harness compiles this single
# driver twice — once linked against the C reference static library,
# once against the Rust static library (whose ffi.rs must export the
# SAME #[no_mangle] extern "C" symbols as uv.h).
#
# Output: JSON to stdout.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_DIR")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust-libuv"
FFI_DIR="$ROOT_DIR/libuv/ffi-test"
FFI_RS="$RUST_DIR/src/ffi.rs"
C_API_H="$ROOT_DIR/libuv/source/include/uv.h"
DRIVER_C="$FFI_DIR/compare_tests.c"

# ============================================================
# 1. API coverage analysis
# ============================================================

# Derive expected public function names from uv.h.
# Match uv_* function declarations (UV_EXTERN ... uv_name(...))
EXPECTED_FUNCS=""
if [ -f "$C_API_H" ]; then
  EXPECTED_FUNCS=$(grep -oE '\buv_[a-z0-9_]+[[:space:]]*\(' "$C_API_H" \
    | sed 's/[[:space:]]*($//' | sort -u)
fi
EXPECTED_COUNT=$(echo "$EXPECTED_FUNCS" | grep -c . || true)

# From ffi.rs extract which uv_* exports are present.
IMPLEMENTED_FUNCS=""
if [ -f "$FFI_RS" ]; then
  IMPLEMENTED_FUNCS=$(grep 'pub use.*uv_' "$FFI_RS" \
    | sed 's/.*:://' | sed 's/;//' \
    | grep -oE '\buv_[a-z0-9_]+' | sort -u)
fi
IMPLEMENTED_COUNT=$(echo "$IMPLEMENTED_FUNCS" | grep -c . || true)

# Per-category expected/implemented counts
VER_EXPECTED=$(echo "$EXPECTED_FUNCS"    | grep -c "version" || true)
VER_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -c "version" || true)
LOOP_EXPECTED=$(echo "$EXPECTED_FUNCS"   | grep -cE "loop_|default_loop" || true)
LOOP_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -cE "loop_|default_loop" || true)
TIMER_EXPECTED=$(echo "$EXPECTED_FUNCS"  | grep -c "timer" || true)
TIMER_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -c "timer" || true)

# ============================================================
# 2. Preconditions
# ============================================================

if [ ! -f "$FFI_RS" ]; then
  printf '{"pass": false, "ffi_present": false, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": 0}, "message": "ffi.rs not found"}\n' \
    "$EXPECTED_COUNT"
  exit 0
fi

if [ ! -d "$RUST_DIR" ] || [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "message": "rust-libuv/ not found"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT"
  exit 0
fi

if [ ! -f "$DRIVER_C" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "message": "compare_tests.c not found"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT"
  exit 0
fi

if [ ! -f "$FFI_DIR/Makefile" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "message": "Makefile not found"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT"
  exit 0
fi

# ============================================================
# 3. Build the C reference static library + compare-c
# ============================================================

cd "$FFI_DIR"
rm -rf build

if ! make compare-c >/tmp/equiv-c-build.log 2>&1; then
  C_BUILD_ERROR=$(head -c 500 /tmp/equiv-c-build.log 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "c_build_error": "%s", "message": "C library build failed"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$C_BUILD_ERROR"
  cp /tmp/equiv-c-build.log /tmp/equiv-detail.log 2>/dev/null || true
  exit 0
fi

# ============================================================
# 4. Build the Rust static library
# ============================================================

cd "$RUST_DIR"
RUST_BUILD_OK=false
RUST_ERROR=""

if timeout 600 cargo build --release >/tmp/equiv-rust-build.log 2>&1; then
  PACKAGE_NAME=$(grep '^name' Cargo.toml 2>/dev/null | head -1 | sed 's/.*= *"\(.*\)"/\1/')
  if [ -z "$PACKAGE_NAME" ]; then
    PACKAGE_NAME="libuv"
  fi

  RUST_LIB=""
  for lib in "target/release/lib${PACKAGE_NAME}.a" "target/release/lib${PACKAGE_NAME}.rlib" \
             "target/release/libuv.a" "target/release/libuv.rlib"; do
    if [ -f "$lib" ]; then
      RUST_LIB="$lib"
      break
    fi
  done
  if [ -n "$RUST_LIB" ]; then
    cp "$RUST_LIB" "$FFI_DIR/build/libuv_rust.a"
    RUST_BUILD_OK=true
  else
    RUST_ERROR="Rust library file not found after build"
  fi
else
  RUST_ERROR=$(head -5 /tmp/equiv-rust-build.log 2>/dev/null | tr '\n' ' ' | head -c 200 | sed 's/"/\\"/g')
fi

if [ "$RUST_BUILD_OK" = false ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "rust_build_error": "%s", "message": "Rust library build failed"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$RUST_ERROR"
  exit 0
fi

# ============================================================
# 5. Compile the Rust-port binary
# ============================================================

cd "$FFI_DIR"

if ! make compare-rust >/tmp/equiv-compile-rust.log 2>&1; then
  LINK_ERROR=$(head -5 /tmp/equiv-compile-rust.log 2>/dev/null | tr '\n' ' ' | head -c 300 | sed 's/"/\\"/g')
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "link_error": "%s", "message": "compare_rust link failed"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$LINK_ERROR"
  exit 0
fi

# ============================================================
# 6. Run both binaries, capture CASE-line stdout
# ============================================================

timeout 300 build/compare_c    >/tmp/equiv-c-out.txt    2>/tmp/equiv-c-stderr.log    || true
timeout 300 build/compare_rust >/tmp/equiv-rust-out.txt 2>/tmp/equiv-rust-stderr.log || true

LC_ALL=C sort /tmp/equiv-c-out.txt   -o /tmp/equiv-c-out.sorted
LC_ALL=C sort /tmp/equiv-rust-out.txt -o /tmp/equiv-rust-out.sorted

LC_ALL=C comm -12 /tmp/equiv-c-out.sorted /tmp/equiv-rust-out.sorted > /tmp/equiv-match.txt
LC_ALL=C comm -23 /tmp/equiv-c-out.sorted /tmp/equiv-rust-out.sorted > /tmp/equiv-only-c.txt
LC_ALL=C comm -13 /tmp/equiv-c-out.sorted /tmp/equiv-rust-out.sorted > /tmp/equiv-only-rust.txt

# ============================================================
# 7. Build synthetic TEST_OUTPUT
# ============================================================

TEST_OUTPUT=""

while IFS= read -r line; do
  [ -z "$line" ] && continue
  cid=$(printf '%s' "$line" | awk '{print $3}')
  cat=$(printf '%s' "$line" | awk '{print $2}')
  [ -z "$cid" ] && continue
  TEST_OUTPUT="${TEST_OUTPUT}${cat} ${cid} PASS"$'\n'
done < /tmp/equiv-match.txt

while IFS= read -r line; do
  [ -z "$line" ] && continue
  cid=$(printf '%s' "$line" | awk '{print $3}')
  cat=$(printf '%s' "$line" | awk '{print $2}')
  [ -z "$cid" ] && continue
  TEST_OUTPUT="${TEST_OUTPUT}${cat} ${cid} FAIL"$'\n'
done < /tmp/equiv-only-c.txt

while IFS= read -r line; do
  [ -z "$line" ] && continue
  cid=$(printf '%s' "$line" | awk '{print $3}')
  cat=$(printf '%s' "$line" | awk '{print $2}')
  [ -z "$cid" ] && continue
  TEST_OUTPUT="${TEST_OUTPUT}${cat} ${cid} FAIL"$'\n'
done < /tmp/equiv-only-rust.txt

CASE_TOTAL=$(printf '%s' "$TEST_OUTPUT" | grep -c . || true)
CASE_PASSED=$(printf '%s' "$TEST_OUTPUT" | grep -c "PASS" || true)
CASE_FAILED=$(printf '%s' "$TEST_OUTPUT" | grep -c "FAIL" || true)

# ============================================================
# 8. Per-category breakdown
# ============================================================

VER_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^version_info .*PASS" || true)
VER_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^version_info .*FAIL" || true)
SIZE_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^sizes .*PASS" || true)
SIZE_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^sizes .*FAIL" || true)
ERR_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^error_strings .*PASS" || true)
ERR_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^error_strings .*FAIL" || true)
LOOP_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^loop_lifecycle .*PASS" || true)
LOOP_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^loop_lifecycle .*FAIL" || true)
TIMER_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^timer_ops .*PASS" || true)
TIMER_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^timer_ops .*FAIL" || true)
SYS_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^system_info .*PASS" || true)
SYS_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^system_info .*FAIL" || true)

PASS="false"
if [ "$CASE_TOTAL" -gt 0 ] && [ "$CASE_FAILED" -eq 0 ]; then
  PASS="true"
fi

# ============================================================
# 9. Output JSON
# ============================================================

printf '{\n'
printf '  "pass": %s,\n' "$PASS"
printf '  "ffi_present": true,\n'
printf '  "passed": %d,\n' "$CASE_PASSED"
printf '  "failed": %d,\n' "$CASE_FAILED"
printf '  "total": %d,\n' "$CASE_TOTAL"
printf '  "api_coverage": {\n'
printf '    "expected": %d,\n' "$EXPECTED_COUNT"
printf '    "implemented": %d\n' "$IMPLEMENTED_COUNT"
printf '  },\n'
printf '  "details": {\n'
printf '    "version_info": {"passed": %d, "failed": %d},\n' "$VER_PASS" "$VER_FAIL"
printf '    "sizes": {"passed": %d, "failed": %d},\n' "$SIZE_PASS" "$SIZE_FAIL"
printf '    "error_strings": {"passed": %d, "failed": %d},\n' "$ERR_PASS" "$ERR_FAIL"
printf '    "loop_lifecycle": {"passed": %d, "failed": %d},\n' "$LOOP_PASS" "$LOOP_FAIL"
printf '    "timer_ops": {"passed": %d, "failed": %d},\n' "$TIMER_PASS" "$TIMER_FAIL"
printf '    "system_info": {"passed": %d, "failed": %d}\n' "$SYS_PASS" "$SYS_FAIL"
printf '  }\n'
printf '}\n'

if [ "$CASE_FAILED" -gt 0 ]; then
  echo "--- Equivalence diff (C vs Rust) ---" >&2
  echo "[only in C reference output]:" >&2
  cat /tmp/equiv-only-c.txt >&2
  echo "[only in Rust output]:" >&2
  cat /tmp/equiv-only-rust.txt >&2
fi

exit 0
