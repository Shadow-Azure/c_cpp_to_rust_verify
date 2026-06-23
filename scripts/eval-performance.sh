#!/usr/bin/env bash
# eval-performance.sh — 评测 Rust 性能是否达标
# 先编译运行 C benchmark 获取基线，再运行 Rust benchmark 对比
# 输出 JSON 结果到 stdout

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FLASHDB_DIR="${PROJECT_ROOT}/flashdb"
RUST_DIR="${PROJECT_ROOT}/rust-flashdb"
CONFIG_FILE="${PROJECT_ROOT}/eval-config.json"

# 读取最大性能回退比例 (默认 1.5)
MAX_RATIO=$(python3 -c "
import json, sys
with open('${CONFIG_FILE}') as f:
    cfg = json.load(f)
print(cfg.get('performance', {}).get('max_regression_ratio', 1.5))
" 2>/dev/null || echo "1.5")

# ============================================================
# 1. 编译并运行 C benchmark
# ============================================================
C_BENCH_DIR="${FLASHDB_DIR}/tests/benchmark"
C_RESULT_FILE=$(mktemp)

echo "Building C benchmark..." >&2
cd "$C_BENCH_DIR"
make clean 2>/dev/null || true
make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)" 2>&1 >&2

echo "Running C benchmark..." >&2
# C benchmark 输出格式: [metric_name] avg: XXXX us
C_OUTPUT=$(./fdb_bench 2>&1 || true)
echo "$C_OUTPUT" > "$C_RESULT_FILE"

# 解析 C 结果: 提取每项指标的平均耗时 (微秒)
parse_c_metric() {
  local metric="$1"
  echo "$C_OUTPUT" | grep -i "$metric" | grep -o 'avg: *[0-9.]*' | grep -o '[0-9.]*' | head -1 || echo "0"
}

C_KVDB_SET_STRING=$(parse_c_metric "set.*string")
C_KVDB_SET_BLOB=$(parse_c_metric "set.*blob")
C_KVDB_GET_STRING=$(parse_c_metric "get.*string")
C_KVDB_GET_BLOB=$(parse_c_metric "get.*blob")
C_KVDB_UPDATE=$(parse_c_metric "update")
C_KVDB_ITERATE=$(parse_c_metric "iterate.*kvdb\|kvdb.*iterate")
C_KVDB_DELETE=$(parse_c_metric "delete")
C_TSDB_APPEND=$(parse_c_metric "append")
C_TSDB_ITERATE=$(parse_c_metric "iterate.*tsdb\|tsdb.*iterate")
C_TSDB_ITER_BY_TIME=$(parse_c_metric "iter.*time\|time.*iter")
C_TSDB_QUERY_COUNT=$(parse_c_metric "query.*count\|count.*query")

# ============================================================
# 2. 编译并运行 Rust benchmark
# ============================================================
RUST_RESULT_FILE=$(mktemp)

if [ ! -d "$RUST_DIR" ]; then
  cat <<EOF
{
  "pass": false,
  "detail": "rust-flashdb/ directory not found",
  "c_baseline": {},
  "rust_result": {},
  "ratio": -1
}
EOF
  exit 1
fi

echo "Building Rust benchmark..." >&2
cd "$RUST_DIR"

RUST_OUTPUT=$(cargo bench 2>&1 || true)
echo "$RUST_OUTPUT" > "$RUST_RESULT_FILE"

# 解析 Rust 结果 (cargo bench 输出格式: test bench_xxx ... bench: XXX ns/iter)
parse_rust_metric() {
  local metric="$1"
  # cargo bench 输出 ns/iter，转换为 us
  local ns
  ns=$(echo "$RUST_OUTPUT" | grep -i "$metric" | grep -o 'bench: *[0-9,]*' | grep -o '[0-9,]*' | tr -d ',' | head -1)
  if [ -n "$ns" ] && [ "$ns" != "0" ]; then
    echo "scale=2; $ns / 1000" | bc 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

RUST_KVDB_SET_STRING=$(parse_rust_metric "set.*string\|kvdb_set_string")
RUST_KVDB_SET_BLOB=$(parse_rust_metric "set.*blob\|kvdb_set_blob")
RUST_KVDB_GET_STRING=$(parse_rust_metric "get.*string\|kvdb_get_string")
RUST_KVDB_GET_BLOB=$(parse_rust_metric "get.*blob\|kvdb_get_blob")
RUST_KVDB_UPDATE=$(parse_rust_metric "update\|kvdb_update")
RUST_KVDB_ITERATE=$(parse_rust_metric "iterate\|kvdb_iterate")
RUST_KVDB_DELETE=$(parse_rust_metric "delete\|kvdb_delete")
RUST_TSDB_APPEND=$(parse_rust_metric "append\|tsdb_append")
RUST_TSDB_ITERATE=$(parse_rust_metric "iterate.*tsdb\|tsdb_iterate")
RUST_TSDB_ITER_BY_TIME=$(parse_rust_metric "iter.*time\|tsdb_iter_by_time")
RUST_TSDB_QUERY_COUNT=$(parse_rust_metric "query.*count\|tsdb_query_count")

# ============================================================
# 3. 计算性能比
# ============================================================
calc_ratio() {
  local c_val="$1"
  local rust_val="$2"
  if [ "$c_val" = "0" ] || [ -z "$c_val" ]; then
    echo "0"
    return
  fi
  echo "scale=2; $rust_val / $c_val" | bc 2>/dev/null || echo "0"
}

R_KVDB_SET_STRING=$(calc_ratio "$C_KVDB_SET_STRING" "$RUST_KVDB_SET_STRING")
R_KVDB_SET_BLOB=$(calc_ratio "$C_KVDB_SET_BLOB" "$RUST_KVDB_SET_BLOB")
R_KVDB_GET_STRING=$(calc_ratio "$C_KVDB_GET_STRING" "$RUST_KVDB_GET_STRING")
R_KVDB_GET_BLOB=$(calc_ratio "$C_KVDB_GET_BLOB" "$RUST_KVDB_GET_BLOB")
R_KVDB_UPDATE=$(calc_ratio "$C_KVDB_UPDATE" "$RUST_KVDB_UPDATE")
R_KVDB_ITERATE=$(calc_ratio "$C_KVDB_ITERATE" "$RUST_KVDB_ITERATE")
R_KVDB_DELETE=$(calc_ratio "$C_KVDB_DELETE" "$RUST_KVDB_DELETE")
R_TSDB_APPEND=$(calc_ratio "$C_TSDB_APPEND" "$RUST_TSDB_APPEND")
R_TSDB_ITERATE=$(calc_ratio "$C_TSDB_ITERATE" "$RUST_TSDB_ITERATE")
R_TSDB_ITER_BY_TIME=$(calc_ratio "$C_TSDB_ITER_BY_TIME" "$RUST_TSDB_ITER_BY_TIME")
R_TSDB_QUERY_COUNT=$(calc_ratio "$C_TSDB_QUERY_COUNT" "$RUST_TSDB_QUERY_COUNT")

# 计算平均比率 (排除 0 值)
RATIOS=($R_KVDB_SET_STRING $R_KVDB_SET_BLOB $R_KVDB_GET_STRING $R_KVDB_GET_BLOB $R_KVDB_UPDATE $R_KVDB_ITERATE $R_KVDB_DELETE $R_TSDB_APPEND $R_TSDB_ITERATE $R_TSDB_ITER_BY_TIME $R_TSDB_QUERY_COUNT)
SUM=0
COUNT=0
for r in "${RATIOS[@]}"; do
  if [ "$r" != "0" ]; then
    SUM=$(echo "$SUM + $r" | bc 2>/dev/null || echo "$SUM")
    COUNT=$((COUNT + 1))
  fi
done

if [ "$COUNT" -gt 0 ]; then
  AVG_RATIO=$(echo "scale=2; $SUM / $COUNT" | bc 2>/dev/null || echo "0")
else
  AVG_RATIO="0"
fi

# 判断是否通过
PASS=$(python3 -c "
ratio = float('${AVG_RATIO}') if '${AVG_RATIO}' else 0
max_r = float('${MAX_RATIO}')
print('true' if 0 < ratio <= max_r else 'false')
" 2>/dev/null || echo "false")

# 清理临时文件
rm -f "$C_RESULT_FILE" "$RUST_RESULT_FILE"

# 输出 JSON
cat <<EOF
{
  "pass": ${PASS},
  "max_ratio_allowed": ${MAX_RATIO},
  "avg_ratio": ${AVG_RATIO},
  "c_baseline": {
    "kvdb_set_string_us": ${C_KVDB_SET_STRING:-0},
    "kvdb_set_blob_us": ${C_KVDB_SET_BLOB:-0},
    "kvdb_get_string_us": ${C_KVDB_GET_STRING:-0},
    "kvdb_get_blob_us": ${C_KVDB_GET_BLOB:-0},
    "kvdb_update_us": ${C_KVDB_UPDATE:-0},
    "kvdb_iterate_us": ${C_KVDB_ITERATE:-0},
    "kvdb_delete_us": ${C_KVDB_DELETE:-0},
    "tsdb_append_us": ${C_TSDB_APPEND:-0},
    "tsdb_iterate_us": ${C_TSDB_ITERATE:-0},
    "tsdb_iter_by_time_us": ${C_TSDB_ITER_BY_TIME:-0},
    "tsdb_query_count_us": ${C_TSDB_QUERY_COUNT:-0}
  },
  "rust_result": {
    "kvdb_set_string_us": ${RUST_KVDB_SET_STRING:-0},
    "kvdb_set_blob_us": ${RUST_KVDB_SET_BLOB:-0},
    "kvdb_get_string_us": ${RUST_KVDB_GET_STRING:-0},
    "kvdb_get_blob_us": ${RUST_KVDB_GET_BLOB:-0},
    "kvdb_update_us": ${RUST_KVDB_UPDATE:-0},
    "kvdb_iterate_us": ${RUST_KVDB_ITERATE:-0},
    "kvdb_delete_us": ${RUST_KVDB_DELETE:-0},
    "tsdb_append_us": ${RUST_TSDB_APPEND:-0},
    "tsdb_iterate_us": ${RUST_TSDB_ITERATE:-0},
    "tsdb_iter_by_time_us": ${RUST_TSDB_ITER_BY_TIME:-0},
    "tsdb_query_count_us": ${RUST_TSDB_QUERY_COUNT:-0}
  },
  "ratios": {
    "kvdb_set_string": ${R_KVDB_SET_STRING:-0},
    "kvdb_set_blob": ${R_KVDB_SET_BLOB:-0},
    "kvdb_get_string": ${R_KVDB_GET_STRING:-0},
    "kvdb_get_blob": ${R_KVDB_GET_BLOB:-0},
    "kvdb_update": ${R_KVDB_UPDATE:-0},
    "kvdb_iterate": ${R_KVDB_ITERATE:-0},
    "kvdb_delete": ${R_KVDB_DELETE:-0},
    "tsdb_append": ${R_TSDB_APPEND:-0},
    "tsdb_iterate": ${R_TSDB_ITERATE:-0},
    "tsdb_iter_by_time": ${R_TSDB_ITER_BY_TIME:-0},
    "tsdb_query_count": ${R_TSDB_QUERY_COUNT:-0}
  }
}
EOF
exit 0
