# c2rust build environment with openSUSE
# Using openSUSE for SUSE repository compatibility
FROM opensuse/leap:15.5

LABEL maintainer="Shadow-Azure"
LABEL description="c2rust v0.15.0 build environment with LLVM 7 on openSUSE"

# Install system dependencies
# openSUSE Leap 15.5 has LLVM 7 in the default repos
RUN zypper --non-interactive install \
    -y \
    patterns-devel-base-devel_basis \
    cmake \
    curl \
    git \
    llvm7-devel \
    clang7-devel \
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
# openSUSE puts LLVM 7 binaries in /usr/lib/llvm7/bin/
RUN ln -sf /usr/lib/llvm7/bin/llvm-config /usr/bin/llvm-config && \
    ln -sf /usr/lib/llvm7/bin/clang /usr/bin/clang && \
    ln -sf /usr/lib/llvm7/bin/clang++ /usr/bin/clang++

# Set LLVM environment for c2rust build system
ENV LLVM_CONFIG_PATH=/usr/lib/llvm7/bin/llvm-config
ENV LIBCLANG_PATH=/usr/lib/llvm7/lib

# Install Rust (latest stable for c2rust v0.15.0)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    --default-toolchain stable

ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTUP_HOME="/root/.rustup"
ENV CARGO_HOME="/root/.cargo"

WORKDIR /build
CMD ["/bin/bash"]
