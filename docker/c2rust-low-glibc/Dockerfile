# c2rust low-GLIBC build environment
# Base: Ubuntu 18.04 (Bionic) → GLIBC 2.27, compatible with GLIBC 2.25+ targets
# LLVM/Clang 7 from Ubuntu default repos
FROM ubuntu:18.04

LABEL maintainer="Shadow-Azure"
LABEL description="c2rust v0.15.0 build environment with LLVM 7, low GLIBC compatibility"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Use Ubuntu archive mirrors (Aliyun for China mainland speed)
RUN sed -i 's|archive.ubuntu.com|mirrors.aliyun.com|g' /etc/apt/sources.list && \
    sed -i 's|security.ubuntu.com|mirrors.aliyun.com|g' /etc/apt/sources.list

# Install system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    curl \
    git \
    llvm-7-dev \
    clang-7 \
    libclang-7-dev \
    libssl-dev \
    pkg-config \
    python3 \
    python3-pip \
    zlib1g-dev \
    ca-certificates \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Create symlinks so llvm-config and clang are available without version suffix
RUN update-alternatives --install /usr/bin/llvm-config llvm-config /usr/bin/llvm-config-7 100 && \
    update-alternatives --install /usr/bin/clang clang /usr/bin/clang-7 100 && \
    update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-7 100

# Set LLVM environment for c2rust build system
ENV LLVM_CONFIG_PATH=/usr/bin/llvm-config-7
ENV LIBCLANG_PATH=/usr/lib/llvm-7/lib

# Install Rust (nightly-2019-12-05 required by c2rust v0.15.0)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    --default-toolchain nightly-2019-12-05

ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTUP_HOME="/root/.rustup"
ENV CARGO_HOME="/root/.cargo"

# Verify installations
RUN echo "=== GLIBC version ===" && \
    ldd --version | head -1 && \
    echo "=== LLVM version ===" && \
    llvm-config-7 --version && \
    echo "=== Clang version ===" && \
    clang-7 --version | head -1 && \
    echo "=== Rust version ===" && \
    rustc --version && \
    echo "=== Cargo version ===" && \
    cargo --version

WORKDIR /build
CMD ["/bin/bash"]
