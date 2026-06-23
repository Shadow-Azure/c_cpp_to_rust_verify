#!/usr/bin/env bash
# eval-tests.sh — 评测 Rust 测试是否全部通过
# 输出 JSON 结果到 stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="${PROJECT_ROOT}/rust-flashdb"

if [ ! -d "$RUST_DIR" ]; then
  echo '{"pass": false, "passed": 0, "failed": 0, "total": 0, "detail": "rust-flashdb/ directory not found"}'
  exit 0
fi

cd "$RUST_DIR"

# 运行 cargo test，捕获输出（不用 set -e，手动处理退出码）
TEST_OUTPUT=""
EXIT_CODE=0
TEST_OUTPUT=$(cargo test 2>&1) || EXIT_CODE=$?

# 解析测试结果 — 用 sed 替代 grep -oP，更可靠
PASSED=$(echo "$TEST_OUTPUT" | sed -n 's/.*\([0-9]\+\) passed.*/\1/p' | head -1)
FAILED=$(echo "$TEST_OUTPUT" | sed -n 's/.*\([0-9]\+\) failed.*/\1/p' | head -1)
IGNORED=$(echo "$TEST_OUTPUT" | sed -n 's/.*\([0-9]\+\) ignored.*/\1/p' | head -1)

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

# 输出详细测试日志到 stderr
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "--- Test Output ---" >&2
  echo "$TEST_OUTPUT" >&2
fi

exit 0
