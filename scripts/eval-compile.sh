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

# 运行 cargo build，捕获输出（禁用颜色码以确保 grep 匹配）
BUILD_OUTPUT=""
EXIT_CODE=0
BUILD_OUTPUT=$(CARGO_TERM_COLOR=never cargo build 2>&1) || EXIT_CODE=$?

log "--- cargo build exited with code $EXIT_CODE ---"
log "--- Build output (first 200 lines) ---"
echo "$BUILD_OUTPUT" | head -200 | tee -a "$LOG_FILE" >&2
log "--- End build output ---"

# 解析 error 和 warning 数量 — 兼容多种格式
# cargo 格式: "error[E0425]:", "error: could not compile", "warning[E0xxx]:", "warning: ..."
ERROR_COUNT=$(echo "$BUILD_OUTPUT" | grep -cE "^error(\[|$)" || true)
WARNING_COUNT=$(echo "$BUILD_OUTPUT" | grep -cE "^warning[\[: ]" || true)

log "--- Parsed: errors=$ERROR_COUNT, warnings=$WARNING_COUNT ---"

# 统计 unsafe 函数比例 (用 Python 处理复杂的 c2rust 代码结构)
UNSAFE_STATS=$(python3 -c "
import re, glob
total = 0
unsafe = 0
for f in glob.glob('src/*.rs'):
    content = open(f).read()
    parts = re.split(r'\n(?=\s*(?:pub\s+)?(?:unsafe\s+)?(?:extern\s+\"C\"\s+)?fn\s)', content)
    for part in parts:
        if re.search(r'\bfn\s', part):
            total += 1
            if re.search(r'null_mut|null::<|ptr::null|&raw\s+mut', part):
                unsafe += 1
print(f'{total} {unsafe}')
" 2>/dev/null || echo "0 0")
TOTAL_FN=$(echo "$UNSAFE_STATS" | awk '{print $1}')
UNSAFE_FN=$(echo "$UNSAFE_STATS" | awk '{print $2}')
log "--- Unsafe stats: total_fn=$TOTAL_FN, unsafe_fn=$UNSAFE_FN ---"

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
printf '  "warnings": %d,\n' "$WARNING_COUNT"
printf '  "total_fn": %d,\n' "$TOTAL_FN"
printf '  "unsafe_fn": %d\n' "$UNSAFE_FN"
printf '}\n'

exit 0
