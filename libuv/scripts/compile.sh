#!/usr/bin/env bash
# compile.sh — 评测 Rust 代码是否能编译通过（libuv）
# 输出 JSON 结果到 stdout，详细日志到 stderr

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$(dirname "$SCRIPT_DIR")/.." && pwd)"
RUST_DIR="${PROJECT_ROOT}/rust-libuv"
LOG_FILE="/tmp/compile-detail.log"

if [ ! -d "$RUST_DIR" ]; then
  echo '{"pass": false, "errors": -1, "warnings": -1, "detail": "rust-libuv/ directory not found"}'
  exit 0
fi

if [ ! -f "$RUST_DIR/Cargo.toml" ]; then
  echo '{"pass": false, "errors": -1, "warnings": -1, "detail": "Cargo.toml not found in rust-libuv/"}'
  exit 0
fi

cd "$RUST_DIR"

log() { echo "$@" | tee -a "$LOG_FILE" >&2; }

log "--- Starting cargo build in $(pwd) ---"
log "--- Rust version: $(rustc --version 2>&1) ---"
log "--- Cargo version: $(cargo --version 2>&1) ---"

BUILD_OUTPUT=""
EXIT_CODE=0
BUILD_OUTPUT=$(CARGO_TERM_COLOR=never cargo build 2>&1) || EXIT_CODE=$?

log "--- cargo build exited with code $EXIT_CODE ---"
log "--- Build output (first 200 lines) ---"
echo "$BUILD_OUTPUT" | head -200 | tee -a "$LOG_FILE" >&2
log "--- End build output ---"

ERROR_COUNT=$(echo "$BUILD_OUTPUT" | grep -cE "^error(\[|$)" || true)
WARNING_COUNT=$(echo "$BUILD_OUTPUT" | grep -cE "^warning[\[: ]" || true)

log "--- Parsed: errors=$ERROR_COUNT, warnings=$WARNING_COUNT ---"

UNSAFE_STATS=$(python3 -c "
import re, glob
total = 0
unsafe = 0
for f in glob.glob('src/**/*.rs', recursive=True):
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

PASS="false"
if [ "$EXIT_CODE" -eq 0 ]; then
  PASS="true"
fi

printf '{\n'
printf '  "pass": %s,\n' "$PASS"
printf '  "exit_code": %d,\n' "$EXIT_CODE"
printf '  "errors": %d,\n' "$ERROR_COUNT"
printf '  "warnings": %d,\n' "$WARNING_COUNT"
printf '  "total_fn": %d,\n' "$TOTAL_FN"
printf '  "unsafe_fn": %d\n' "$UNSAFE_FN"
printf '}\n'

exit 0
