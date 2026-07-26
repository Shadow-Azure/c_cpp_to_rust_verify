#!/bin/bash
# -----------------------------------------------------------
# Performance benchmark: compare C baseline vs converted Rust.
#
# The framework ships its own Rust benchmark (bench/rust/flashdb_bench.rs),
# a 1:1 port of flashdb/tests/benchmark/bench_main.c that calls the converted
# crate's FFI. Both the C baseline and the Rust bench print the SAME line
# format, so a single parser yields matching metric keys for a direct ratio.
#
# Output: JSON to stdout:
#   {"c_metrics": {...}, "rust_metrics": {...}, "note": "..."}
# Diagnostics: written to stderr (captured into perf-detail.log artifact).
# -----------------------------------------------------------

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
C_BENCH_DIR="$ROOT_DIR/flashdb/tests/benchmark"
RUST_DIR="$ROOT_DIR/rust-flashdb"
FRAMEWORK_BENCH="$ROOT_DIR/bench/rust/flashdb_bench.rs"

C_BUILD_LOG="/tmp/c-bench-build.log"
C_RUN_LOG="/tmp/c-bench-run.log"
RUST_BENCH_LOG="/tmp/rust-bench.log"
C_METRICS_FILE="/tmp/perf-c-metrics.json"
RUST_METRICS_FILE="/tmp/perf-rust-metrics.json"
NOTE_FILE="/tmp/perf-note.txt"

echo '{}' > "$C_METRICS_FILE"
echo '{}' > "$RUST_METRICS_FILE"
: > "$NOTE_FILE"

if [ ! -f "$ROOT_DIR/eval-benchmarks.yml" ]; then
  printf '{"error": "eval-benchmarks.yml not found"}\n'
  exit 0
fi

# Single parser shared by C and Rust output (identical format):
#   "  <name> | <n> ops | <us> us | <ops/s> ops/s | <us/op> us/op"
# Writes {"metrics": {...}} JSON and a diag string to the given out/diag files.
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

# ---------- Run C baseline benchmark ----------
C_BUILD_OK=false
C_RUN_OK=false
if [ -d "$C_BENCH_DIR" ]; then
  if timeout 300 make -C "$C_BENCH_DIR" clean benchmark > "$C_BUILD_LOG" 2>&1; then
    C_BUILD_OK=true
    # File redirect (NOT command substitution): survives a timeout kill, and
    # with unbuffered stdout in bench_main.c every line is flushed as written.
    if timeout 300 "$C_BENCH_DIR/benchmark" > "$C_RUN_LOG" 2>&1; then
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
  cp "$FRAMEWORK_BENCH" "$RUST_DIR/benches/flashdb_bench.rs"
  if ! grep -q 'name = "flashdb_bench"' "$RUST_DIR/Cargo.toml" 2>/dev/null; then
    cat >> "$RUST_DIR/Cargo.toml" << 'TOML_EOF'

[[bench]]
name = "flashdb_bench"
harness = false
TOML_EOF
  fi
  RUST_BENCH_INJECTED=true

  cd "$RUST_DIR" || true
  # cargo bench builds in release; --bench runs only our custom-harness binary.
  if timeout 600 cargo bench --bench flashdb_bench > "$RUST_BENCH_LOG" 2>&1; then
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
    echo "C benchmark run failed or timed out (see perf-detail.log)"
  fi
  if [ "$RUST_BENCH_INJECTED" = false ]; then
    if [ ! -d "$RUST_DIR" ] || [ ! -f "$RUST_DIR/Cargo.toml" ]; then
      echo "no converted Rust crate (rust-flashdb/ not found)"
    elif [ ! -f "$FRAMEWORK_BENCH" ]; then
      echo "framework bench not found (bench/rust/flashdb_bench.rs missing)"
    fi
  elif [ "$RUST_BUILD_OK" = false ]; then
    echo "Rust benchmark build/run failed (FFI drift or compile error; see perf-detail.log)"
  fi
  [ -n "$C_DIAG" ] && echo "C parse: $C_DIAG"
  [ -n "$RUST_DIAG" ] && echo "Rust parse: $RUST_DIAG"
} > "$NOTE_FILE"

# ---------- Dump raw logs to stderr (=> perf-detail.log artifact) ----------
{
  echo "================ C benchmark: build log ================"
  [ -f "$C_BUILD_LOG" ] && cat "$C_BUILD_LOG" || echo "(no build log)"
  echo
  echo "================ C benchmark: run log (last 60 lines) ================"
  [ -f "$C_RUN_LOG" ] && tail -n 60 "$C_RUN_LOG" || echo "(no run log)"
  echo
  echo "================ Rust benchmark: build+run log (last 80 lines) ================"
  [ -f "$RUST_BENCH_LOG" ] && tail -n 80 "$RUST_BENCH_LOG" || echo "(no rust bench log)"
  echo
  echo "================ Summary ================"
  echo "C_BUILD_OK=$C_BUILD_OK C_RUN_OK=$C_RUN_OK RUST_BENCH_INJECTED=$RUST_BENCH_INJECTED RUST_BUILD_OK=$RUST_BUILD_OK"
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
