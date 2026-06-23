#!/usr/bin/env bash
# eval-equivalence.sh — 评测 Rust 转换版与 C 原版的功能等价性
# 通过 FFI 接口调用两个实现，对比输出是否一致
# 输出 JSON 结果到 stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
RUST_DIR="$ROOT_DIR/rust-flashdb"
FFI_DIR="$ROOT_DIR/ffi-compare"

# ============================================================
# 检查前提条件
# ============================================================

# 检查 ffi.rs 是否存在
if [ ! -f "$RUST_DIR/src/ffi.rs" ]; then
  printf '{"pass": false, "ffi_present": false, "passed": 0, "failed": 0, "total": 0, "message": "ffi.rs not found in rust-flashdb/src/"}\n'
  exit 0
fi

# 检查 rust-flashdb 是否存在
if [ ! -d "$RUST_DIR" ] || [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "message": "rust-flashdb/ not found or no Cargo.toml"}\n'
  exit 0
fi

# ============================================================
# 构建 C 静态库
# ============================================================

cd "$FFI_DIR"
rm -rf build

if ! make c-lib 2>/tmp/equiv-c-build.log; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "message": "C library build failed"}\n'
  exit 0
fi

# ============================================================
# 构建 Rust 静态库
# ============================================================

cd "$RUST_DIR"
RUST_BUILD_OK=false

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
  fi
fi

if [ "$RUST_BUILD_OK" = false ]; then
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "message": "Rust library build failed"}\n'
  exit 0
fi

# ============================================================
# 编译并运行对比测试
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
  printf '{"pass": false, "ffi_present": true, "passed": 0, "failed": 0, "total": 0, "message": "compare_tests compilation failed"}\n'
  exit 0
fi

# 运行测试 (超时 5 分钟)
TEST_OUTPUT=$(timeout 300 build/compare_tests 2>&1) || true

# ============================================================
# 解析测试结果
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
# 输出 JSON (用 printf 确保格式干净)
# ============================================================

printf '{\n'
printf '  "pass": %s,\n' "$PASS"
printf '  "ffi_present": true,\n'
printf '  "passed": %d,\n' "$PASSED"
printf '  "failed": %d,\n' "$FAILED"
printf '  "total": %d,\n' "$TOTAL"
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
