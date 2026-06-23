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

# 解析测试结果
# cargo test 输出格式: test result: ok. X passed; Y failed; Z ignored; ...
PASSED=$(echo "$TEST_OUTPUT" | grep -o '[0-9]* passed' | grep -o '[0-9]*' || echo "0")
FAILED=$(echo "$TEST_OUTPUT" | grep -o '[0-9]* failed' | grep -o '[0-9]*' || echo "0")
IGNORED=$(echo "$TEST_OUTPUT" | grep -o '[0-9]* ignored' | grep -o '[0-9]*' || echo "0")

# 默认值
PASSED=${PASSED:-0}
FAILED=${FAILED:-0}
IGNORED=${IGNORED:-0}
TOTAL=$((PASSED + FAILED))

# 判断是否通过
PASS="false"
if [ "$EXIT_CODE" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  PASS="true"
fi

# 输出 JSON
cat <<EOF
{
  "pass": ${PASS},
  "exit_code": ${EXIT_CODE},
  "passed": ${PASSED},
  "failed": ${FAILED},
  "ignored": ${IGNORED},
  "total": ${TOTAL}
}
EOF

# 输出详细测试日志到 stderr
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "--- Test Output ---" >&2
  echo "$TEST_OUTPUT" >&2
fi

exit 0
