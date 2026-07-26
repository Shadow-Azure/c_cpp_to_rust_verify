#!/bin/bash
# -----------------------------------------------------------
# Performance benchmark: compare C baseline vs converted Rust (cJSON).
#
# UNIFIED C DRIVER — same source file (cjson/bench/c/cjson_bench.c) is
# compiled twice and linked against two different static libraries:
#   * bench_c    links libcjson.a        (C reference)
#   * bench_rust links librust_cjson.a   (converted Rust crate)
#
# This mirrors cjson/ffi-test/Makefile's compare-c / compare-rust pattern
# and avoids the algorithmic drift that occurs when two handwritten
# benchmarks (one in C, one in Rust) reimplement the same workload with
# different complexity — the previous design's Rust traverse used indexed
# access on a linked list (O(n²)) while the C version used the
# cJSON_ArrayForEach macro (O(n)), producing a spurious 227x regression.
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

C_BUILD_LOG="/tmp/c-bench-build.log"
C_RUN_LOG="/tmp/c-bench-run.log"
RUST_BUILD_LOG="/tmp/rust-bench-build.log"
RUST_RUN_LOG="/tmp/rust-bench-run.log"
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

if [ ! -f "$C_BENCH_SRC" ]; then
  printf '{"error": "C benchmark source not found: %s"}\n' "$C_BENCH_SRC"
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

# ---------- 1. Build C cJSON static library (if not already) ----------
C_LIB_OK=false
if [ ! -f "$CJSON_DIR/build/libcjson.a" ]; then
  cd "$CJSON_DIR"
  cmake -B build -DENABLE_CJSON_TEST=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release >> "$C_BUILD_LOG" 2>&1
  cmake --build build --config Release >> "$C_BUILD_LOG" 2>&1
  cd "$ROOT_DIR"
fi
[ -f "$CJSON_DIR/build/libcjson.a" ] && C_LIB_OK=true

# ---------- 2. Build the C-reference benchmark binary ----------
C_BUILD_OK=false
C_RUN_OK=false
if [ "$C_LIB_OK" = true ]; then
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

# ---------- 3. Build the Rust static library ----------
RUST_BUILD_OK=false
RUST_LIB=""
if [ -d "$RUST_DIR" ] && [ -f "$RUST_DIR/Cargo.toml" ]; then
  cd "$RUST_DIR"
  if timeout 600 cargo build --release >> "$RUST_BUILD_LOG" 2>&1; then
    RUST_BUILD_OK=true
    PACKAGE_NAME=$(grep '^name' Cargo.toml 2>/dev/null | head -1 | sed 's/.*= *"\(.*\)"/\1/')
    [ -z "$PACKAGE_NAME" ] && PACKAGE_NAME="cjson"
    # c2rust output crate name varies: rust_cjson / cjson / c_json / cJSON / libcjson
    for name in "$PACKAGE_NAME" "cjson" "c_json" "cJSON" "libcjson"; do
      for lib in "target/release/lib${name}.a" "target/release/lib${name}.rlib"; do
        if [ -f "$lib" ]; then
          RUST_LIB="$RUST_DIR/$lib"
          break 2
        fi
      done
    done
    if [ -z "$RUST_LIB" ]; then
      RUST_BUILD_OK=false
      echo "Rust static library not found after build (tried $PACKAGE_NAME, cjson, c_json, cJSON, libcjson)" >> "$NOTE_FILE"
    fi
  else
    echo "Rust crate build failed (cargo build --release)" >> "$NOTE_FILE"
  fi
  cd "$ROOT_DIR"
else
  echo "no converted Rust crate (rust-cjson/ not found)" >> "$NOTE_FILE"
fi

# ---------- 4. Compile the SAME C benchmark against the Rust library ----------
RUST_LINK_OK=false
RUST_RUN_OK=false
if [ "$RUST_BUILD_OK" = true ] && [ -n "$RUST_LIB" ]; then
  # Link the C benchmark against the Rust static library. Every cJSON_*
  # function the benchmark calls must be a #[no_mangle] extern "C" export
  # in the crate's ffi.rs — a missing symbol produces a clear link error
  # instead of a silent algorithmic mismatch.
  #
  # -lm just in case the Rust staticlib pulls in math symbols; cJSON itself
  # has no system deps, but c2rust output occasionally references libc fns.
  if cc -O2 -I "$CJSON_DIR" "$C_BENCH_SRC" "$RUST_LIB" -lm -lpthread \
      -o /tmp/cjson_rust_bench >> "$RUST_BUILD_LOG" 2>&1; then
    RUST_LINK_OK=true
    if timeout 300 /tmp/cjson_rust_bench > "$RUST_RUN_LOG" 2>&1; then
      RUST_RUN_OK=true
    fi
    parse_metrics "$RUST_RUN_LOG" "$RUST_METRICS_FILE" /tmp/perf-rust-diag.txt
  else
    echo "Failed to link C benchmark against Rust library (missing FFI exports?)" >> "$NOTE_FILE"
    tail -15 "$RUST_BUILD_LOG" >> "$NOTE_FILE"
  fi
fi

# ---------- 5. Assemble note ----------
C_DIAG="$(cat /tmp/perf-c-diag.txt 2>/dev/null || true)"
RUST_DIAG="$(cat /tmp/perf-rust-diag.txt 2>/dev/null || true)"
{
  if [ "$C_LIB_OK" = false ]; then
    echo "C cJSON library build failed"
  elif [ "$C_BUILD_OK" = false ]; then
    echo "C benchmark build failed"
  elif [ "$C_RUN_OK" = false ]; then
    echo "C benchmark run failed or timed out"
  fi
  if [ "$RUST_BUILD_OK" = false ]; then
    : # reason already written above
  elif [ "$RUST_LINK_OK" = false ]; then
    : # reason already written above
  elif [ "$RUST_RUN_OK" = false ]; then
    echo "Rust benchmark run failed or timed out"
  fi
  [ -n "$C_DIAG" ] && echo "C parse: $C_DIAG"
  [ -n "$RUST_DIAG" ] && echo "Rust parse: $RUST_DIAG"
} >> "$NOTE_FILE"

# ---------- 6. Dump raw logs to stderr ----------
{
  echo "================ C benchmark: build log ================"
  [ -f "$C_BUILD_LOG" ] && tail -20 "$C_BUILD_LOG" || echo "(no build log)"
  echo
  echo "================ C benchmark: run log ================"
  [ -f "$C_RUN_LOG" ] && cat "$C_RUN_LOG" || echo "(no run log)"
  echo
  echo "================ Rust benchmark: build log ================"
  [ -f "$RUST_BUILD_LOG" ] && tail -25 "$RUST_BUILD_LOG" || echo "(no rust build log)"
  echo
  echo "================ Rust benchmark: run log ================"
  [ -f "$RUST_RUN_LOG" ] && cat "$RUST_RUN_LOG" || echo "(no rust run log)"
} >&2

# ---------- 7. Output JSON ----------
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
