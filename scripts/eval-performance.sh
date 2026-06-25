#!/bin/bash
# -----------------------------------------------------------
# Performance benchmark: compare C vs Rust
# Output: JSON to stdout with per-metric ratios
# -----------------------------------------------------------

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
C_BENCH_DIR="$ROOT_DIR/flashdb/tests/benchmark"
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
if [ -d "$C_BENCH_DIR" ]; then
  if timeout 300 make -C "$C_BENCH_DIR" clean benchmark > /tmp/c-bench-stdout.log 2>/tmp/c-bench-stderr.log; then
    C_BUILD_OK=true
    # Run the benchmark binary
    C_BENCH_OUTPUT=$(timeout 120 "$C_BENCH_DIR/benchmark" 2>&1)
    echo "$C_BENCH_OUTPUT" > /tmp/c-bench-run.log
  fi
fi

if [ "$C_BUILD_OK" = false ]; then
  printf '{"error": "C benchmark build failed", "c_metrics": {}, "rust_metrics": {}}\n'
  exit 0
fi

# ---------- Parse C benchmark results ----------
# C output format: "  %-30s | %6u ops | %9.1f us | %8.1f ops/s | %7.2f us/op"
C_METRICS="{}"
if [ -n "$C_BENCH_OUTPUT" ]; then
  C_METRICS=$(python3 -c "
import re, json, sys

output = open('/tmp/c-bench-run.log').read()
metrics = {}
for line in output.split('\n'):
    m = re.match(r'\s+(.+?)\s+\|\s+(\d+)\s+ops\s+\|\s+([\d.]+)\s+us\s+\|\s+([\d.]+)\s+ops/s\s+\|\s+([\d.]+)\s+us/op', line)
    if m:
        name = m.group(1).strip()
        us_per_op = float(m.group(5))
        # Normalize name to match YAML keys
        key = name.lower().replace(' ', '_').replace('(', '').replace(')', '')
        metrics[key] = round(us_per_op, 2)
print(json.dumps(metrics))
" 2>/dev/null)
fi

# ---------- Run Rust benchmarks ----------
RUST_BENCH_OUTPUT=""
RUST_BUILD_OK=false
RUST_HAS_BENCH=false
if [ -d "$RUST_DIR" ] && [ -f "$RUST_DIR/Cargo.toml" ]; then
  # Check if benches/ directory exists or [[bench]] in Cargo.toml
  if [ -d "$RUST_DIR/benches" ] || grep -q '\[\[bench\]\]' "$RUST_DIR/Cargo.toml" 2>/dev/null; then
    RUST_HAS_BENCH=true
    cd "$RUST_DIR"
    if timeout 600 cargo bench 2>&1 | tee /tmp/rust-bench.log; then
      RUST_BUILD_OK=true
      RUST_BENCH_OUTPUT=$(cat /tmp/rust-bench.log)
    fi
    cd "$ROOT_DIR"
  fi
fi

# ---------- Parse Rust benchmark results ----------
RUST_METRICS="{}"
if [ "$RUST_BUILD_OK" = true ] && [ -n "$RUST_BENCH_OUTPUT" ]; then
  RUST_METRICS=$(python3 -c "
import re, json, sys

output = open('/tmp/rust-bench.log').read()
metrics = {}
for line in output.split('\n'):
    m = re.match(r'(\w[\w_]*)\s+.*?([\d.]+)\s+(ns|us|ms|s)/op', line)
    if m:
        name, val, unit = m.group(1), float(m.group(2)), m.group(3)
        mult = {'ns': 0.001, 'us': 1, 'ms': 1000, 's': 1000000}
        metrics[name] = round(val * mult.get(unit, 1), 2)
print(json.dumps(metrics))
" 2>/dev/null)
fi

# ---------- Output JSON ----------
if [ "$RUST_HAS_BENCH" = false ]; then
  printf '{"c_metrics": %s, "rust_metrics": {}, "note": "no Rust benchmarks (benches/ not generated)"}\n' "$C_METRICS"
else
  printf '{"c_metrics": %s, "rust_metrics": %s}\n' "$C_METRICS" "$RUST_METRICS"
fi
