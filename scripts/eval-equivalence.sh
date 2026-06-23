#!/usr/bin/env bash
# eval-equivalence.sh — 评测 Rust 转换版与 C 原版的功能等价性
# 1. API 覆盖率: 对比 rust_ffi.h 声明 vs ffi.rs 实现
# 2. 功能等价: 通过 FFI 调用两个实现，对比输出
# 输出 JSON 结果到 stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$ROOT_DIR/rust-flashdb"
FFI_DIR="$ROOT_DIR/ffi-compare"
FFI_H="$FFI_DIR/rust_ffi.h"
FFI_RS="$RUST_DIR/src/ffi.rs"

# ============================================================
# 1. API 覆盖率分析
# ============================================================

# 从 rust_ffi.h 提取期望的函数名 (fdb_rust_* 函数)
EXPECTED_FUNCS=""
if [ -f "$FFI_H" ]; then
  EXPECTED_FUNCS=$(grep -oE 'fdb_rust_[a-z_]+' "$FFI_H" | sort -u)
fi
EXPECTED_COUNT=$(echo "$EXPECTED_FUNCS" | grep -c . || true)

# 从 ffi.rs 提取实际实现的 #[no_mangle] extern "C" 函数
IMPLEMENTED_FUNCS=""
if [ -f "$FFI_RS" ]; then
  # 匹配 "pub extern "C" fn fdb_rust_*" 模式
  IMPLEMENTED_FUNCS=$(grep -oE 'fdb_rust_[a-z_]+' "$FFI_RS" | sort -u)
fi
IMPLEMENTED_COUNT=$(echo "$IMPLEMENTED_FUNCS" | grep -c . || true)

# 计算各类别覆盖率
CRC_EXPECTED=$(echo "$EXPECTED_FUNCS" | grep -c "crc32" || true)
CRC_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -c "crc32" || true)

KV_EXPECTED=$(echo "$EXPECTED_FUNCS" | grep -c "kvdb\|kv_" || true)
KV_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -c "kvdb\|kv_" || true)

TS_EXPECTED=$(echo "$EXPECTED_FUNCS" | grep -c "tsdb\|tsl_" || true)
TS_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -c "tsdb\|tsl_" || true)

# free_string 是通用函数
FREE_EXPECTED=$(echo "$EXPECTED_FUNCS" | grep -c "free_string" || true)
FREE_IMPLEMENTED=$(echo "$IMPLEMENTED_FUNCS" | grep -c "free_string" || true)

# ============================================================
# 检查前提条件
# ============================================================

# 检查 ffi.rs 是否存在
if [ ! -f "$FFI_RS" ]; then
  printf '{"pass": false, "ffi_present": false, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": 0, "crc32": {"expected": %d, "implemented": 0}, "kvdb": {"expected": %d, "implemented": 0}, "tsdb": {"expected": %d, "implemented": 0}}, "message": "ffi.rs not found"}\n' \
    "$EXPECTED_COUNT" "$CRC_EXPECTED" "$KV_EXPECTED" "$TS_EXPECTED"
  exit 0
fi

# 检查 rust-flashdb 是否存在
if [ ! -d "$RUST_DIR" ] || [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d, "crc32": {"expected": %d, "implemented": %d}, "kvdb": {"expected": %d, "implemented": %d}, "tsdb": {"expected": %d, "implemented": %d}}, "message": "rust-flashdb/ not found"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$CRC_EXPECTED" "$CRC_IMPLEMENTED" "$KV_EXPECTED" "$KV_IMPLEMENTED" "$TS_EXPECTED" "$TS_IMPLEMENTED"
  exit 0
fi

# ============================================================
# 2. 构建 C 静态库
# ============================================================

cd "$FFI_DIR"
rm -rf build

if ! make c-lib 2>/tmp/equiv-c-build.log; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "message": "C library build failed"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT"
  exit 0
fi

# ============================================================
# 3. 构建 Rust 静态库
# ============================================================

cd "$RUST_DIR"
RUST_BUILD_OK=false
RUST_ERROR=""

# 尝试 cargo build --release，超时 10 分钟
if timeout 600 cargo build --release 2>/tmp/equiv-rust-build.log; then
  # 查找编译产物
  RUST_LIB=""
  for lib in target/release/libflashdb.a target/release/libflashdb.rlib; do
    if [ -f "$lib" ]; then
      RUST_LIB="$lib"
      break
    fi
  done

  if [ -n "$RUST_LIB" ]; then
    cp "$RUST_LIB" "$FFI_DIR/build/libflashdb_rust.a"
    RUST_BUILD_OK=true
  else
    RUST_ERROR="Rust library file not found after build (no .a or .rlib)"
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
# 4. 编译并运行对比测试
# ============================================================

cd "$FFI_DIR"

# 编译 compare_tests
if ! cc -O0 -g3 -Wall -Wno-format \
    -I"$ROOT_DIR/flashdb/inc" \
    -I"$ROOT_DIR/flashdb/tests" \
    -I. \
    -DFDB_USING_FILE_MODE -DFDB_USING_FILE_POSIX_MODE \
    -DFDB_WRITE_GRAN=1 -DFDB_USING_KVDB -DFDB_USING_TSDB \
    -o build/compare_tests \
    compare_tests.c \
    build/libflashdb_c.a \
    build/libflashdb_rust.a \
    -lpthread 2>/tmp/equiv-compile.log; then
  LINK_ERROR=$(head -3 /tmp/equiv-compile.log 2>/dev/null | tr '\n' ' ' | head -c 200)
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "api_coverage": {"expected": %d, "implemented": %d}, "link_error": "%s", "message": "compare_tests link failed"}\n' \
    "$EXPECTED_COUNT" "$IMPLEMENTED_COUNT" "$LINK_ERROR"
  exit 0
fi

# 运行测试 (超时 5 分钟)
TEST_OUTPUT=$(timeout 300 build/compare_tests 2>&1) || true

# ============================================================
# 5. 解析测试结果
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
# 6. 输出 JSON (用 printf 确保格式干净)
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

# 输出详细日志到 stderr
if [ "$FAILED" -gt 0 ]; then
  echo "--- Test Output ---" >&2
  echo "$TEST_OUTPUT" >&2
fi

exit 0
