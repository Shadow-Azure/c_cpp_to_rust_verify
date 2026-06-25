#!/usr/bin/env bash
# eval-compile.sh — 评测 Rust 代码是否能编译通过
# 输出 JSON 结果到 stdout，详细日志到 stderr

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="${PROJECT_ROOT}/rust-flashdb"
LOG_FILE="/tmp/compile-detail.log"

if [ ! -d "$RUST_DIR" ]; then
  echo '{"pass": false, "errors": -1, "warnings": -1, "detail": "rust-flashdb/ directory not found"}'
  exit 0
fi

if [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  echo '{"pass": false, "errors": -1, "warnings": -1, "detail": "Cargo.toml not found in rust-flashdb/"}'
  exit 0
fi

cd "$RUST_DIR"

log() { echo "$@" | tee -a "$LOG_FILE" >&2; }

log "--- Starting cargo build in $(pwd) ---"
log "--- Rust version: $(rustc --version 2>&1) ---"
log "--- Cargo version: $(cargo --version 2>&1) ---"

# 运行 cargo build，捕获输出
BUILD_OUTPUT=""
EXIT_CODE=0
BUILD_OUTPUT=$(cargo build 2>&1) || EXIT_CODE=$?

log "--- cargo build exited with code $EXIT_CODE ---"
log "--- Build output (first 200 lines) ---"
echo "$BUILD_OUTPUT" | head -200 | tee -a "$LOG_FILE" >&2
log "--- End build output ---"

# 解析 error 和 warning 数量 — 兼容多种格式
# cargo 格式: "error[E0425]:", "error: could not compile", "warning[E0xxx]:"
ERROR_COUNT=$(echo "$BUILD_OUTPUT" | grep -cE "^error(\[|$)" || true)
WARNING_COUNT=$(echo "$BUILD_OUTPUT" | grep -cE "^warning(\[|$)" || true)

log "--- Parsed: errors=$ERROR_COUNT, warnings=$WARNING_COUNT ---"

# 判断是否通过
PASS="false"
if [ "$EXIT_CODE" -eq 0 ]; then
  PASS="true"
fi

# 输出 JSON
printf '{\n'
printf '  "pass": %s,\n' "$PASS"
printf '  "exit_code": %d,\n' "$EXIT_CODE"
printf '  "errors": %d,\n' "$ERROR_COUNT"
printf '  "warnings": %d\n' "$WARNING_COUNT"
printf '}\n'

exit 0
