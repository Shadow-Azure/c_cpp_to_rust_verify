# c2rust Low GLIBC Build

在低 GLIBC 环境中构建 c2rust v0.15.0，确保二进制文件兼容 GLIBC ≥ 2.25 的系统。

## 构建环境

| 组件 | 版本 | 说明 |
|------|------|------|
| Base Image | Ubuntu 18.04 (Bionic) | GLIBC 2.27 |
| LLVM | 7.0 | c2rust 最低要求 |
| Clang | 7.0 | 对应 LLVM 7 |
| Rust | nightly-2019-12-05 | c2rust v0.15.0 要求 |
| c2rust | 0.15.0 | 目标版本 |

## 文件结构

```
docker/c2rust-low-glibc/Dockerfile   # Docker 构建环境
scripts/build-c2rust.sh              # 本地构建脚本
.github/workflows/build-c2rust-release.yml  # GitHub Actions 工作流
```

## 本地构建

```bash
# 构建 Docker 镜像并编译 c2rust
./scripts/build-c2rust.sh

# 指定输出目录
./scripts/build-c2rust.sh /path/to/output
```

构建产物：
- `output/c2rust` — 主二进制文件
- `output/c2rust-transpile` — 转译器（如有）
- `output/c2rust-refactor` — 重构工具（如有）
- `output/c2rust-0.15.0-x86_64-linux-gnu.tar.gz` — 打包文件

## GitHub Actions 工作流

### 手动触发

1. 进入 Actions → "Build & Release c2rust (Low GLIBC)"
2. 点击 "Run workflow"
3. 输入 c2rust 版本号（默认 0.15.0）

### Tag 触发

```bash
git tag c2rust-v0.15.0
git push origin c2rust-v0.15.0
```

## GLIBC 兼容性验证

构建后可检查二进制文件的 GLIBC 需求：

```bash
# 查看所需的 GLIBC 版本
objdump -T output/c2rust | grep GLIBC | awk '{print $5}' | sed 's/GLIBC_//' | sort -V | uniq

# 查看动态链接库依赖
ldd output/c2rust
```

## 为什么选择 Ubuntu 18.04？

- **GLIBC 2.27** — 兼容 GLIBC ≥ 2.25 的系统
- **LLVM 7 在默认仓库中** — 无需编译 LLVM 或使用第三方源
- **Rust nightly-2019-12-05 兼容** — 使用旧版 Rust 工具链
- **比 Debian 9 更稳定** — 软件包更完整

## 与现有 Dockerfile 的区别

| 特性 | 现有 Dockerfile | c2rust-low-glibc |
|------|----------------|------------------|
| 基础镜像 | Ubuntu 22.04 | Ubuntu 18.04 |
| GLIBC | 2.35 | 2.27 |
| LLVM | 系统默认 (14+) | 7.0 |
| Rust | stable + nightly-2023-04-15 | nightly-2019-12-05 |
| 用途 | 评估流水线 | 低 GLIBC 兼容性构建 |
