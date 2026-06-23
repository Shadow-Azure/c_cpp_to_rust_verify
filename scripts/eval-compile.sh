#!/usr/bin/env bash
# eval-compile.sh — 评测 Rust 代码是否能编译通过
# 输出 JSON 结果到 stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RUST_DIR="${PROJECT_ROOT}/rust-flashdb"

if [ ! -d "$RUST_DIR" ]; then
  echo '{"pass": false, "errors": -1, "warnings": -1, "detail": "rust-flashdb/ directory not found"}'
  exit 0
fi

cd "$RUST_DIR"

# 运行 cargo build，捕获输出
BUILD_OUTPUT=""
EXIT_CODE=0
BUILD_OUTPUT=$(cargo build 2>&1) || EXIT_CODE=$?

# 解析 error 和 warning 数量
ERROR_COUNT=$(echo "$BUILD_OUTPUT" | grep -c "^error\[" || true)
WARNING_COUNT=$(echo "$BUILD_OUTPUT" | grep -c "^warning" || true)

# 判断是否通过
PASS="false"
if [ "$EXIT_CODE" -eq 0 ]; then
  PASS="true"
fi

# 输出 JSON
cat <<EOF
{
  "pass": ${PASS},
  "exit_code": ${EXIT_CODE},
  "errors": ${ERROR_COUNT},
  "warnings": ${WARNING_COUNT}
}
EOF

# 同时输出详细编译日志到 stderr
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "--- Compile Errors ---" >&2
  echo "$BUILD_OUTPUT" >&2
fi

exit 0
