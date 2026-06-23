#!/bin/bash
# -----------------------------------------------------------
# Performance benchmark: compare C vs Rust
# Output: JSON to stdout with per-metric ratios
# -----------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
C_DIR="$ROOT_DIR/c"
RUST_DIR="$ROOT_DIR/rust-flashdb"

# ---------- Load expected metrics from YAML ----------
METRICS_YAML="$ROOT_DIR/eval-benchmarks.yml"
if [ ! -f "$METRICS_YAML" ]; then
  printf '{"error": "eval-benchmarks.yml not found"}\n'
  exit 0
fi

EXPECTED_METRICS=$(python3 -c "
import yaml, sys
with open('$METRICS_YAML') as f:
    data = yaml.safe_load(f)
metrics = data.get('metrics', [])
for m in metrics:
    print(m['name'])
" 2>/dev/null)

if [ -z "$EXPECTED_METRICS" ]; then
  printf '{"error": "no metrics found in YAML"}\n'
  exit 0
fi

# ---------- Run C benchmarks ----------
C_BENCH_OUTPUT=""
C_BUILD_OK=false
if [ -d "$C_DIR" ]; then
  cd "$C_DIR/fdb"
  if [ -f "Makefile" ]; then
    mkdir -p build
    if timeout 300 make -C build -f ../Makefile benchmark > /tmp/c-bench-stdout.log 2>/tmp/c-bench-stderr.log; then
      C_BUILD_OK=true
      C_BENCH_OUTPUT=$(cat /tmp/c-bench-stdout.log)
    fi
  fi
  cd "$ROOT_DIR"
fi

if [ "$C_BUILD_OK" = false ]; then
  printf '{"error": "C benchmark build failed", "c_metrics": {}, "rust_metrics": {}}\n'
  exit 0
fi

# ---------- Parse C benchmark results ----------
C_METRICS="{}"
if [ -n "$C_BENCH_OUTPUT" ]; then
  C_METRICS=$(python3 -c "
import re, json, sys
output = '''$C_BENCH_OUTPUT'''
metrics = {}
for line in output.split('\n'):
    m = re.match(r'(\w[\w_]*)\s+.*?([\d.]+)\s+(ns|us|ms|s)/op', line)
    if m:
        name, val, unit = m.group(1), float(m.group(2)), m.group(3)
        mult = {'ns': 1, 'us': 1000, 'ms': 1000000, 's': 1000000000}
        metrics[name] = int(val * mult.get(unit, 1))
print(json.dumps(metrics))
" 2>/dev/null)
fi

# ---------- Run Rust benchmarks ----------
RUST_BENCH_OUTPUT=""
RUST_BUILD_OK=false
if [ -d "$RUST_DIR" ]; then
  cd "$RUST_DIR"
  if [ -f "Cargo.toml" ]; then
    if timeout 600 cargo bench 2>&1 | tee /tmp/rust-bench.log; then
      RUST_BUILD_OK=true
      RUST_BENCH_OUTPUT=$(cat /tmp/rust-bench.log)
    fi
  fi
  cd "$ROOT_DIR"
fi

if [ "$RUST_BUILD_OK" = false ]; then
  printf '{"error": "Rust benchmark build failed", "c_metrics": %s, "rust_metrics": {}}\n' "$C_METRICS"
  exit 0
fi

# ---------- Parse Rust benchmark results ----------
RUST_METRICS="{}"
if [ -n "$RUST_BENCH_OUTPUT" ]; then
  RUST_METRICS=$(python3 -c "
import re, json, sys
output = '''$RUST_BENCH_OUTPUT'''
metrics = {}
for line in output.split('\n'):
    m = re.match(r'(\w[\w_]*)\s+.*?([\d.]+)\s+(ns|us|ms|s)/op', line)
    if m:
        name, val, unit = m.group(1), float(m.group(2)), m.group(3)
        mult = {'ns': 1, 'us': 1000, 'ms': 1000000, 's': 1000000000}
        metrics[name] = int(val * mult.get(unit, 1))
print(json.dumps(metrics))
" 2>/dev/null)
fi

# ---------- Output JSON ----------
printf '{"c_metrics": %s, "rust_metrics": %s}\n' "$C_METRICS" "$RUST_METRICS"
