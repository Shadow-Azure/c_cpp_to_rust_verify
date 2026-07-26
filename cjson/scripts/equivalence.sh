#!/usr/bin/env bash
# equivalence.sh — evaluate functional equivalence between the Rust
# port and the original C cJSON using a TWO-BINARY comparison.
#
# Model: the test driver (cjson/ffi-test/compare_tests.c) calls the
# public cJSON C API by its ORIGINAL symbol names (cJSON_Parse,
# cJSON_GetObjectItem, cJSON_Print, ...). The harness compiles this
# single driver twice — once linked against the C reference static
# library (libcjson.a), once against the Rust static library (whose
# ffi.rs must export the SAME #[no_mangle] extern "C" symbols as
# cJSON.h).
#
# Output: JSON to stdout.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_DIR")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust-cjson"
FFI_DIR="$ROOT_DIR/cjson/ffi-test"
FFI_RS="$RUST_DIR/src/ffi.rs"
C_API_H="$ROOT_DIR/cjson/source/cJSON.h"
DRIVER_C="$FFI_DIR/compare_tests.c"

# ============================================================
# 1. API coverage analysis
# ============================================================

# Derive expected public function names from cJSON.h.
# Match cJSON_* declarations (CJSON_PUBLIC(...) cJSON_Name(...)).
# cJSON function names contain uppercase JSON, so use [a-zA-Z0-9_].
EXPECTED_FUNCS=""
if [ -f "$C_API_H" ]; then
  EXPECTED_FUNCS=$(grep -oE '\bcJSON_[a-zA-Z0-9_]+[[:space:]]*\(' "$C_API_H" \
    | sed 's/[[:space:]]*($//' | sort -u)
fi
EXPECTED_COUNT=$(echo "$EXPECTED_FUNCS" | grep -c . || true)

# From ffi.rs extract which cJSON_* exports are present. Covers both
# `pub use crate::...::cJSON_Foo;` re-exports AND
# `#[no_mangle] extern "C" fn cJSON_Foo(...)` direct definitions.
IMPLEMENTED_FUNCS=""
if [ -f "$FFI_RS" ]; then
  IMPLEMENTED_FUNCS=$(grep -oE '\bcJSON_[a-zA-Z0-9_]+' "$FFI_RS" | sort -u)
fi
IMPLEMENTED_COUNT=$(echo "$IMPLEMENTED_FUNCS" | grep -c . || true)

# Per-category expected/implemented counts
PARS_EXPECTED=$(echo "$EXPECTED_FUNCS"        | grep -cE "^cJSON_(Parse|GetErrorPtr)" || true)
PARS_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS"  | grep -cE "^cJSON_(Parse|GetErrorPtr)" || true)
PRNT_EXPECTED=$(echo "$EXPECTED_FUNCS"        | grep -cE "^cJSON_Print" || true)
PRNT_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS"  | grep -cE "^cJSON_Print" || true)
TYPE_EXPECTED=$(echo "$EXPECTED_FUNCS"        | grep -cE "^cJSON_Is" || true)
TYPE_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS"  | grep -cE "^cJSON_Is" || true)
ACC_EXPECTED=$(echo "$EXPECTED_FUNCS"         | grep -cE "^cJSON_(Get|Has)" || true)
ACC_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS"   | grep -cE "^cJSON_(Get|Has)" || true)
CRT_EXPECTED=$(echo "$EXPECTED_FUNCS"         | grep -cE "^cJSON_Create" || true)
CRT_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS"   | grep -cE "^cJSON_Create" || true)

# ============================================================
# 2. Preconditions
# ============================================================

if [ ! -f "$FFI_RS" ]; then
  printf '{"pass": false, "ffi_present": false, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": 0}, "message": "ffi.rs not found"}\n' \
    "$EXPECTED_COUNT"
  exit 0
fi

if [ ! -d "$RUST_DIR" ] || [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "message": "rust-cjson/ not found"}\n' \
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
    PACKAGE_NAME="cjson"
  fi

  # Try multiple guesses — c2rust may produce cjson / c_json / cJSON / libcjson
  RUST_LIB=""
  for name in "$PACKAGE_NAME" "cjson" "c_json" "cJSON" "libcjson"; do
    for lib in "target/release/lib${name}.a" "target/release/lib${name}.rlib"; do
      if [ -f "$lib" ]; then
        RUST_LIB="$lib"
        break 2
      fi
    done
  done
  if [ -n "$RUST_LIB" ]; then
    cp "$RUST_LIB" "$FFI_DIR/build/libcjson_rust.a"
    RUST_BUILD_OK=true
  else
    RUST_ERROR="Rust library file not found after build (tried $PACKAGE_NAME, cjson, c_json, cJSON, libcjson)"
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

VER_PASS=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^version_info .*PASS" || true)
VER_FAIL=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^version_info .*FAIL" || true)
PBASIC_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^parse_basic .*PASS" || true)
PBASIC_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^parse_basic .*FAIL" || true)
PERR_PASS=$(printf '%s' "$TEST_OUTPUT"  | grep -c "^parse_errors .*PASS" || true)
PERR_FAIL=$(printf '%s' "$TEST_OUTPUT"  | grep -c "^parse_errors .*FAIL" || true)
PRINT_PASS=$(printf '%s' "$TEST_OUTPUT" | grep -c "^print .*PASS" || true)
PRINT_FAIL=$(printf '%s' "$TEST_OUTPUT" | grep -c "^print .*FAIL" || true)
TYPE_PASS=$(printf '%s' "$TEST_OUTPUT"  | grep -c "^type_check .*PASS" || true)
TYPE_FAIL=$(printf '%s' "$TEST_OUTPUT"  | grep -c "^type_check .*FAIL" || true)
ACC_PASS=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^access .*PASS" || true)
ACC_FAIL=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^access .*FAIL" || true)
CRT_PASS=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^create .*PASS" || true)
CRT_FAIL=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^create .*FAIL" || true)
ADD_PASS=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^add .*PASS" || true)
ADD_FAIL=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^add .*FAIL" || true)
MOD_PASS=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^modify .*PASS" || true)
MOD_FAIL=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^modify .*FAIL" || true)
DEL_PASS=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^delete .*PASS" || true)
DEL_FAIL=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^delete .*FAIL" || true)
UTL_PASS=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^utils .*PASS" || true)
UTL_FAIL=$(printf '%s' "$TEST_OUTPUT"   | grep -c "^utils .*FAIL" || true)

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
printf '    "parse_basic": {"passed": %d, "failed": %d},\n' "$PBASIC_PASS" "$PBASIC_FAIL"
printf '    "parse_errors": {"passed": %d, "failed": %d},\n' "$PERR_PASS" "$PERR_FAIL"
printf '    "print": {"passed": %d, "failed": %d},\n' "$PRINT_PASS" "$PRINT_FAIL"
printf '    "type_check": {"passed": %d, "failed": %d},\n' "$TYPE_PASS" "$TYPE_FAIL"
printf '    "access": {"passed": %d, "failed": %d},\n' "$ACC_PASS" "$ACC_FAIL"
printf '    "create": {"passed": %d, "failed": %d},\n' "$CRT_PASS" "$CRT_FAIL"
printf '    "add": {"passed": %d, "failed": %d},\n' "$ADD_PASS" "$ADD_FAIL"
printf '    "modify": {"passed": %d, "failed": %d},\n' "$MOD_PASS" "$MOD_FAIL"
printf '    "delete": {"passed": %d, "failed": %d},\n' "$DEL_PASS" "$DEL_FAIL"
printf '    "utils": {"passed": %d, "failed": %d}\n' "$UTL_PASS" "$UTL_FAIL"
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
