# c2rust build environment with openSUSE
# Using openSUSE for SUSE repository compatibility
FROM opensuse/leap:15.5

LABEL maintainer="Shadow-Azure"
LABEL description="c2rust v0.15.0 build environment with LLVM 9 on openSUSE"

# Install system dependencies
RUN zypper --non-interactive install \
    -y \
    patterns-devel-base-devel_basis \
    cmake \
    curl \
    git \
    llvm9-devel \
    clang9 \
    libclang9-devel \
    libopenssl-devel \
    pkg-config \
    python3 \
    python3-pip \
    zlib-devel \
    ca-certificates \
    xz \
    gcc \
    gcc-c++ \
    make

# Create symlinks so llvm-config and clang are available without version suffix
RUN ln -sf /usr/bin/llvm-config-9 /usr/bin/llvm-config && \
    ln -sf /usr/bin/clang-9 /usr/bin/clang && \
    ln -sf /usr/bin/clang++-9 /usr/bin/clang++

# Set LLVM environment for c2rust build system
ENV LLVM_CONFIG_PATH=/usr/bin/llvm-config-9
ENV LIBCLANG_PATH=/usr/lib/llvm9/lib

# Install Rust (latest stable for c2rust v0.15.0)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    --default-toolchain stable

ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTUP_HOME="/root/.rustup"
ENV CARGO_HOME="/root/.cargo"

# Verify installations
RUN echo "=== GLIBC version ===" && \
    ldd --version | head -1 && \
    echo "=== LLVM version ===" && \
    llvm-config-9 --version && \
    echo "=== Clang version ===" && \
    clang-9 --version | head -1 && \
    echo "=== Rust version ===" && \
    rustc --version && \
    echo "=== Cargo version ===" && \
    cargo --version

WORKDIR /build
CMD ["/bin/bash"]
