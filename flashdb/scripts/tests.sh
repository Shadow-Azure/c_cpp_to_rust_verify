#!/usr/bin/env bash
# eval-tests.sh — 评测 Rust 测试是否全部通过
# 输出 JSON 结果到 stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="${PROJECT_ROOT}/rust-flashdb"
LOG_FILE="/tmp/test-detail.log"

if [ ! -d "$RUST_DIR" ]; then
  echo '{"pass": false, "passed": 0, "failed": 0, "total": 0, "detail": "rust-flashdb/ directory not found"}'
  exit 0
fi

cd "$RUST_DIR"

log() { echo "$@" | tee -a "$LOG_FILE" >&2; }

log "--- Starting cargo test in $(pwd) ---"
log "--- Rust version: $(rustc --version 2>&1) ---"
log "--- Cargo version: $(cargo --version 2>&1) ---"

# 运行 cargo test，捕获输出（禁用颜色码以确保解析匹配）
TEST_OUTPUT=""
EXIT_CODE=0
TEST_OUTPUT=$(CARGO_TERM_COLOR=never cargo test 2>&1) || EXIT_CODE=$?

log "--- cargo test exited with code $EXIT_CODE ---"
log "--- Test output (first 200 lines) ---"
echo "$TEST_OUTPUT" | head -200 | tee -a "$LOG_FILE" >&2
log "--- End test output ---"

# timeout 命令返回 124 表示超时
if [ "$EXIT_CODE" -eq 124 ]; then
  printf '{\n'
  printf '  "pass": false,\n'
  printf '  "passed": 0,\n'
  printf '  "failed": 0,\n'
  printf '  "ignored": 0,\n'
  printf '  "total": 0,\n'
  printf '  "timeout": true,\n'
  printf '  "message": "cargo test timed out after 600s"\n'
  printf '}\n'
  log "--- TIMEOUT: cargo test exceeded 600s ---"
  exit 0
fi

# 解析测试结果 — 聚合所有 test result: 行（unit tests + integration tests）
# 使用 grep -oE 提取数字，awk 累加
PASSED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ passed' | awk '{sum+=$1} END {print sum+0}')
FAILED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ failed' | awk '{sum+=$1} END {print sum+0}')
IGNORED=$(echo "$TEST_OUTPUT" | grep -oE '[0-9]+ ignored' | awk '{sum+=$1} END {print sum+0}')

# 确保有默认值
PASSED=${PASSED:-0}
FAILED=${FAILED:-0}
IGNORED=${IGNORED:-0}
TOTAL=$((PASSED + FAILED))

# 判断是否通过
PASS="false"
if [ "$EXIT_CODE" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  PASS="true"
fi

# 输出 JSON（用 printf 确保格式干净）
printf '{\n'
printf '  "pass": %s,\n' "$PASS"
printf '  "exit_code": %d,\n' "$EXIT_CODE"
printf '  "passed": %d,\n' "$PASSED"
printf '  "failed": %d,\n' "$FAILED"
printf '  "ignored": %d,\n' "$IGNORED"
printf '  "total": %d\n' "$TOTAL"
printf '}\n'

# 输出详细测试日志
if [ "$EXIT_CODE" -ne 0 ]; then
  log "--- Full Test Output ---"
  echo "$TEST_OUTPUT" | tee -a "$LOG_FILE" >&2
fi

exit 0
