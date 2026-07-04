# CLAUDE.md - Project Knowledge Base

## 项目概述

C/C++ 到 Rust 迁移验证和评估项目。使用 AI 编码代理（OpenCode + DeepSeek）自动将 FlashDB 的 C 源代码转换为 Rust，然后评估转换质量。

## GitHub 仓库

- **验证仓库**: `Shadow-Azure/c_cpp_to_rust_verify` - 运行评估流水线
- **Skill 仓库**: `Shadow-Azure/c_cpp_to_rust` - c-to-rust skill 开发和发布

## 阿里云服务器

- **IP**: 47.98.144.243
- **用户**: root (SSH 密码认证)
- **系统**: Ubuntu 24.04.4 LTS (x86_64)
- **SSH 连接**: `ssh root@47.98.144.243` (需要密码)

## Self-hosted Runners

服务器上运行两个 GitHub Actions Runner：

| Runner 名称 | 仓库 | 服务名 | 版本 |
|-------------|------|--------|------|
| self-hosted-linux | c_cpp_to_rust_verify | github-runner | 2.335.1 |
| c2rust-build | c_cpp_to_rust | github-runner-c2rust | 2.335.1 |

**Runner 目录**:
- `c_cpp_to_rust_verify`: `/home/runner/actions-runner/`
- `c_cpp_to_rust`: `/home/runner/actions-runner-c2rust/`

**服务管理**:
```bash
systemctl status github-runner        # 查看状态
systemctl restart github-runner       # 重启
systemctl status github-runner-c2rust # c_cpp_to_rust 的 runner
```

## Docker 镜像

**预构建镜像** (阿里云 VPC 内网):
```
crpi-asv0cbh8pj2ubw6j-vpc.cn-hangzhou.personal.cr.aliyuncs.com/shadow_azure/github:c2rust-runner-latest
```

**镜像内容**:
- Ubuntu 22.04
- Rust 工具链 (rustc 1.96.1)
- OpenCode (opencode-ai)
- GitHub CLI (gh)
- clang/bear/make/gcc
- ripgrep

**Docker 镜像仓库**:
- Registry: `crpi-asv0cbh8pj2ubw6j.cn-hangzhou.personal.cr.aliyuncs.com`
- 命名空间: `shadow_azure`
- 仓库名: `github`

**Docker 镜像源**: 阿里云加速器 `https://4u6rq79q.mirror.aliyuncs.com`

## 流水线配置

### evaluate.yml (c_cpp_to_rust_verify)

- **触发**: push to main, PR, workflow_dispatch
- **Runner**: self-hosted + Docker 容器
- **超时**: Convert 90min, Evaluate 60min
- **模型**: deepseek/deepseek-v4-pro
- **Environment**: production (需要审批)

### release.yml (c_cpp_to_rust)

- **触发**: push tags `v*`
- **Runner**: self-hosted + Docker 容器
- **构建**: translator, runtime-check, c2rust

## GitHub API 常用命令

```bash
# 查看 Runner 状态
gh api "repos/Shadow-Azure/c_cpp_to_rust_verify/actions/runners"

# 获取 Runner registration token
gh api --method POST "repos/Shadow-Azure/c_cpp_to_rust_verify/actions/runners/registration-token" --jq '.token'

# 查看流水线运行
gh run list --repo Shadow-Azure/c_cpp_to_rust_verify --limit 10

# 审批流水线
gh api --method POST "repos/Shadow-Azure/c_cpp_to_rust_verify/actions/runs/<RUN_ID>/pending_deployments" --input - <<'EOF'
{"environment_ids": [17041174712], "state": "approved", "comment": "Approved"}
EOF
```

## 评估维度

| 维度 | 权重 | 说明 |
|------|------|------|
| 编译 | 40% | cargo build 是否成功 |
| 测试 | 20% | cargo test 通过率 |
| 功能等价 | 25% | FFI 接口测试 |
| 性能 | 15% | 不超过 1.5x 回归 |

## 已知问题

1. **GitHub Actions 免费额度**: 每月 2000 分钟，已耗尽时使用 self-hosted runner
2. **Docker 镜像拉取**: 阿里云服务器需要配置镜像加速器
3. **Runner 版本**: 两个 Runner 需要保持版本一致

## 版本历史

| 版本 | 评估轮次 | 总分 | 关键问题 |
|------|---------|------|---------|
| v0.2.1 | eval 19 | 40% | 缺少 FFI 层 |
| v0.2.3 | eval 22 | 0% | Cargo.toml 空 workspace |
| v0.2.6 | eval 24 | 40% | 缺少 FFI 层 |
