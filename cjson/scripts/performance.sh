#!/bin/bash
# -----------------------------------------------------------
# Performance benchmark: compare C baseline vs converted Rust (cJSON).
#
# The framework ships a C benchmark (cjson/bench/c/cjson_bench.c) and
# a Rust benchmark (cjson/bench/cjson_bench.rs). Both print the SAME
# line format, so a single parser yields matching metric keys.
#
# Output: JSON to stdout:
#   {"c_metrics": {...}, "rust_metrics": {...}, "note": "..."}
# -----------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_DIR")/.." && pwd)"
C_BENCH_SRC="$ROOT_DIR/cjson/bench/c/cjson_bench.c"
CJSON_DIR="$ROOT_DIR/cjson/source"
RUST_DIR="$ROOT_DIR/rust-cjson"
FRAMEWORK_BENCH="$ROOT_DIR/cjson/bench/cjson_bench.rs"

C_BUILD_LOG="/tmp/c-bench-build.log"
C_RUN_LOG="/tmp/c-bench-run.log"
RUST_BENCH_LOG="/tmp/rust-bench.log"
C_METRICS_FILE="/tmp/perf-c-metrics.json"
RUST_METRICS_FILE="/tmp/perf-rust-metrics.json"
NOTE_FILE="/tmp/perf-note.txt"

echo '{}' > "$C_METRICS_FILE"
echo '{}' > "$RUST_METRICS_FILE"
: > "$NOTE_FILE"

if [ ! -f "$ROOT_DIR/cjson/eval-benchmarks.yml" ]; then
  printf '{"error": "cjson/eval-benchmarks.yml not found"}\n'
  exit 0
fi

# Single parser shared by C and Rust output (identical format):
parse_metrics() {
  local infile="$1" outfile="$2" diagfile="$3"
  python3 - "$infile" "$outfile" "$diagfile" << 'PYEOF'
import re, json, sys
infile, outfile, diagfile = sys.argv[1], sys.argv[2], sys.argv[3]
metrics = {}
diag = ""
try:
    output = open(infile, errors="replace").read()
except Exception as e:
    diag = "cannot read %s: %s" % (infile, e)
    open(outfile, "w").write("{}")
    open(diagfile, "w").write(diag)
    raise SystemExit
matched = 0
for line in output.split("\n"):
    m = re.match(r"\s+(.+?)\s+\|\s+(\d+)\s+ops\s+\|\s+([\d.]+)\s+us\s+\|\s+([\d.]+)\s+ops/s\s+\|\s+([\d.]+)\s+us/op", line)
    if m:
        name = m.group(1).strip()
        us_per_op = float(m.group(5))
        key = name.lower().replace(" ", "_").replace("(", "").replace(")", "")
        metrics[key] = round(us_per_op, 2)
        matched += 1
if matched == 0:
    sample = [l.strip() for l in output.split("\n") if l.strip()][:8]
    diag = "no result lines matched expected format. Sample: " + repr(sample)
open(outfile, "w").write(json.dumps(metrics))
open(diagfile, "w").write(diag)
PYEOF
}

# ---------- Build and run C benchmark ----------
C_BUILD_OK=false
C_RUN_OK=false
if [ -f "$C_BENCH_SRC" ]; then
  # Build C cJSON static library first (if not already built)
  if [ ! -f "$CJSON_DIR/build/libcjson.a" ]; then
    cd "$CJSON_DIR"
    cmake -B build -DENABLE_CJSON_TEST=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release >> "$C_BUILD_LOG" 2>&1
    cmake --build build --config Release >> "$C_BUILD_LOG" 2>&1
    cd "$ROOT_DIR"
  fi

  # Compile benchmark. cJSON has no system library dependencies.
  if cc -O2 -I "$CJSON_DIR" "$C_BENCH_SRC" \
      "$CJSON_DIR/build/libcjson.a" \
      -o /tmp/cjson_c_bench >> "$C_BUILD_LOG" 2>&1; then
    C_BUILD_OK=true
    if timeout 300 /tmp/cjson_c_bench > "$C_RUN_LOG" 2>&1; then
      C_RUN_OK=true
    fi
    parse_metrics "$C_RUN_LOG" "$C_METRICS_FILE" /tmp/perf-c-diag.txt
  fi
fi

# ---------- Run framework-provided Rust benchmark ----------
RUST_BENCH_INJECTED=false
RUST_BUILD_OK=false
if [ -d "$RUST_DIR" ] && [ -f "$RUST_DIR/Cargo.toml" ] && [ -f "$FRAMEWORK_BENCH" ]; then
  mkdir -p "$RUST_DIR/benches"
  cp "$FRAMEWORK_BENCH" "$RUST_DIR/benches/cjson_bench.rs"
  if ! grep -q 'name = "cjson_bench"' "$RUST_DIR/Cargo.toml" 2>/dev/null; then
    cat >> "$RUST_DIR/Cargo.toml" << 'TOML_EOF'

[[bench]]
name = "cjson_bench"
harness = false
TOML_EOF
  fi
  RUST_BENCH_INJECTED=true

  cd "$RUST_DIR" || true
  if timeout 600 cargo bench --bench cjson_bench > "$RUST_BENCH_LOG" 2>&1; then
    RUST_BUILD_OK=true
  fi
  cd "$ROOT_DIR" || true
  parse_metrics "$RUST_BENCH_LOG" "$RUST_METRICS_FILE" /tmp/perf-rust-diag.txt
fi

# ---------- Assemble note ----------
C_DIAG="$(cat /tmp/perf-c-diag.txt 2>/dev/null || true)"
RUST_DIAG="$(cat /tmp/perf-rust-diag.txt 2>/dev/null || true)"
{
  if [ "$C_BUILD_OK" = false ]; then
    echo "C benchmark build failed"
  elif [ "$C_RUN_OK" = false ]; then
    echo "C benchmark run failed or timed out"
  fi
  if [ "$RUST_BENCH_INJECTED" = false ]; then
    if [ ! -d "$RUST_DIR" ] || [ ! -f "$RUST_DIR/Cargo.toml" ]; then
      echo "no converted Rust crate (rust-cjson/ not found)"
    elif [ ! -f "$FRAMEWORK_BENCH" ]; then
      echo "framework bench not found"
    fi
  elif [ "$RUST_BUILD_OK" = false ]; then
    echo "Rust benchmark build/run failed"
  fi
  [ -n "$C_DIAG" ] && echo "C parse: $C_DIAG"
  [ -n "$RUST_DIAG" ] && echo "Rust parse: $RUST_DIAG"
} > "$NOTE_FILE"

# ---------- Dump raw logs to stderr ----------
{
  echo "================ C benchmark: build log ================"
  [ -f "$C_BUILD_LOG" ] && tail -20 "$C_BUILD_LOG" || echo "(no build log)"
  echo
  echo "================ C benchmark: run log ================"
  [ -f "$C_RUN_LOG" ] && cat "$C_RUN_LOG" || echo "(no run log)"
  echo
  echo "================ Rust benchmark: log ================"
  [ -f "$RUST_BENCH_LOG" ] && tail -40 "$RUST_BENCH_LOG" || echo "(no rust bench log)"
} >&2

# ---------- Output JSON to stdout ----------
python3 - "$C_METRICS_FILE" "$RUST_METRICS_FILE" "$NOTE_FILE" << 'PYEOF'
import json, sys
c_file, r_file, note_file = sys.argv[1], sys.argv[2], sys.argv[3]
def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}
note = ""
try:
    with open(note_file) as f:
        note = f.read().strip()
except Exception:
    pass
print(json.dumps({"c_metrics": load(c_file), "rust_metrics": load(r_file), "note": note}))
PYEOF
