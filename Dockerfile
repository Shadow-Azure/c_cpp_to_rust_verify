FROM ubuntu:22.04

# 配置 DNS
RUN echo "nameserver 8.8.8.8" > /etc/resolv.conf && \
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf

# 使用阿里云 apt 源（加速）
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

# 安装系统依赖
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    jq \
    python3 \
    sudo \
    software-properties-common \
    make \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# 安装 GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && \
    apt-get install -y gh && \
    rm -rf /var/lib/apt/lists/*

# 安装 c-to-rust 依赖
RUN apt-get update && apt-get install -y \
    clang \
    bear \
    libtinfo5 \
    && rm -rf /var/lib/apt/lists/*

# 安装 Node.js (用于 OpenCode)
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    npm config set registry https://registry.npmmirror.com && \
    rm -rf /var/lib/apt/lists/*

# 安装 OpenCode
RUN npm install -g opencode-ai

# 使用 rsproxy.cn 镜像源（阿里云主机到 USTC 不稳定，实测 USTC 17KB/s 卡死，rsproxy 16.7MB/s）
ENV RUSTUP_DIST_SERVER=https://rsproxy.cn
ENV RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup

# 安装 Rust 工具链（使用国内 rustup 安装器）
RUN curl -sSf -o /tmp/rustup-init https://rsproxy.cn/rustup/dist/x86_64-unknown-linux-gnu/rustup-init && \
    chmod +x /tmp/rustup-init && \
    /tmp/rustup-init -y --default-toolchain stable && \
    . "$HOME/.cargo/env" && \
    rustup component add rustfmt clippy && \
    rustup toolchain install nightly-2023-04-15 --profile minimal && \
    rm /tmp/rustup-init

# 安装 ripgrep (代码搜索工具) - 使用官方地址
RUN curl -LO https://github.com/BurntSushi/ripgrep/releases/download/14.1.0/ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz && \
    tar xzf ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz && \
    mv ripgrep-14.1.0-x86_64-unknown-linux-musl/rg /usr/local/bin/ && \
    rm -rf ripgrep-14.1.0-x86_64-unknown-linux-musl*

# 配置环境变量
ENV PATH="/root/.cargo/bin:${PATH}"
ENV RUSTUP_HOME="/root/.rustup"
ENV CARGO_HOME="/root/.cargo"

# 验证安装
RUN opencode --version && \
    gh --version && \
    clang --version | head -1 && \
    bear --version && \
    make --version | head -1 && \
    gcc --version | head -1 && \
    rustc --version && \
    cargo --version && \
    rg --version | head -1

# 设置工作目录
WORKDIR /workspace

# 默认命令
CMD ["/bin/bash"]
