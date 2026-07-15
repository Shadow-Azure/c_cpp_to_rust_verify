#!/bin/bash
# Build c2rust v0.15.0 in the low-GLIBC Docker environment
# Usage: ./build-c2rust.sh [output_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${1:-${SCRIPT_DIR}/../output}"
IMAGE_NAME="c2rust-low-glibc:latest"
C2RUST_VERSION="0.15.0"

echo "=== Building c2rust ${C2RUST_VERSION} in low-GLIBC environment ==="

# Build the Docker image
echo "[1/3] Building Docker image..."
docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}/../docker/c2rust-low-glibc/"

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Build c2rust inside the container
echo "[2/3] Building c2rust ${C2RUST_VERSION}..."
docker run --rm \
    -v "${OUTPUT_DIR}:/output" \
    "${IMAGE_NAME}" \
    bash -c "
        set -euo pipefail

        echo '=== Cloning c2rust ==='
        git clone --depth 1 --branch ${C2RUST_VERSION} https://github.com/immunant/c2rust.git /build/c2rust
        cd /build/c2rust

        echo '=== Building c2rust (release) ==='
        cargo build --release 2>&1

        echo '=== Collecting binaries ==='
        # c2rust main binary
        cp target/release/c2rust /output/c2rust
        # c2rust-transpile (the transpiler library binary, if built)
        if [ -f target/release/c2rust-transpile ]; then
            cp target/release/c2rust-transpile /output/c2rust-transpile
        fi
        # c2rust-refactor (if built)
        if [ -f target/release/c2rust-refactor ]; then
            cp target/release/c2rust-refactor /output/c2rust-refactor
        fi

        echo '=== Binary info ==='
        file /output/c2rust
        ldd /output/c2rust || true
        /output/c2rust --version || true

        echo '=== Done ==='
    "

# Package the binaries
echo "[3/3] Packaging binaries..."
cd "${OUTPUT_DIR}"
tar czf "c2rust-${C2RUST_VERSION}-x86_64-linux-gnu.tar.gz" c2rust*

echo ""
echo "=== Build complete ==="
echo "Output: ${OUTPUT_DIR}/c2rust-${C2RUST_VERSION}-x86_64-linux-gnu.tar.gz"
echo "Files:"
ls -lh "${OUTPUT_DIR}/"
