# c_cpp_to_rust_verify

C/C++ to Rust 迁移验证仓库：基于 FlashDB f9d042 的反例测试与回归校验。

## 概述

本仓库通过 GitHub Actions 自动化评测 AI 编码工具将 C 代码转换为 Rust 的能力。

**目标项目**: [FlashDB](https://github.com/armink/FlashDB) v2.2.99 (commit f9d042) — 一个高性能嵌入式键值/时序数据库。

**评测维度**:

| 维度 | 权重 | 说明 |
|------|------|------|
| 编译成功 | 50% | Rust 代码能否无错误编译 |
| 测试覆盖 | 30% | 所有测试用例是否通过 |
| 性能不下降 | 20% | 性能回退不超过 1.5 倍 |

## 工作原理

```
┌─────────────┐     ┌──────────────────┐     ┌──────────────────┐
│  Push/PR     │────▶│  OpenCode Agent   │────▶│  rust-flashdb/   │
│  触发 CI     │     │  加载 C2Rust Skill │     │  生成的 Rust 代码 │
└─────────────┘     └──────────────────┘     └────────┬─────────┘
                                                       │
                                              ┌────────▼─────────┐
                                              │   评测 Pipeline   │
                                              │  ┌─────────────┐ │
                                              │  │ 编译评测     │ │
                                              │  │ 测试评测     │ │
                                              │  │ 性能评测     │ │
                                              │  └──────┬──────┘ │
                                              │         │        │
                                              │  ┌──────▼──────┐ │
                                              │  │ 评分聚合     │ │
                                              │  │ 生成报告     │ │
                                              │  └─────────────┘ │
                                              └──────────────────┘
```

## 快速开始

### 配置 GitHub Secrets

在仓库 Settings > Secrets and variables > Actions 中添加:

- `OPENAI_API_KEY` 或 `ANTHROPIC_API_KEY`: AI 模型的 API Key
- 可选: 在 Variables 中设置 `OPENCODE_MODEL` 指定模型 (默认 `anthropic/claude-sonnet-4-20250514`)

### 手动触发

Push 到 `main` 分支或创建 PR 即可自动触发评测。

### 本地运行 Skill

```bash
# 安装 OpenCode CLI
curl -fsSL https://opencode.ai/install | bash

# 在项目根目录运行
opencode run --prompt "/flashdb-c2rust"
```

### 本地运行评测

```bash
# 假设 rust-flashdb/ 已存在
bash scripts/eval-compile.sh > /tmp/compile.json
bash scripts/eval-tests.sh > /tmp/test.json
bash scripts/eval-performance.sh > /tmp/perf.json
python3 scripts/aggregate-score.py /tmp/compile.json /tmp/test.json /tmp/perf.json report.md
```

## 项目结构

```
.
├── .opencode/skills/flashdb-c2rust/
│   └── SKILL.md              # OpenCode Skill: C→Rust 转换指令
├── .github/workflows/
│   └── evaluate.yml           # GitHub Actions 评测流水线
├── flashdb/                   # 原始 FlashDB C 代码 (评测对象)
│   ├── src/                   # C 源文件 (5 个)
│   ├── inc/                   # C 头文件 (4 个)
│   ├── tests/                 # C 单元测试 (24 个用例)
│   └── tests/benchmark/       # C 性能基准
├── scripts/
│   ├── eval-compile.sh        # 编译评测脚本
│   ├── eval-tests.sh          # 测试评测脚本
│   ├── eval-performance.sh    # 性能评测脚本
│   └── aggregate-score.py     # 评分聚合脚本
├── opencode.json              # OpenCode 项目配置
├── eval-config.json           # 评测权重和阈值配置
└── rust-flashdb/              # (运行后生成) Rust 转换结果
```

## 评测报告示例

评测完成后，报告会出现在 GitHub Actions 的 Job Summary 中:

```
# FlashDB C→Rust 迁移评测报告

## 总分: 85.0% (等级: B)

| 维度 | 权重 | 得分 | 状态 |
|------|------|------|------|
| 编译 | 50%  | 100.0% | ✅ 通过 |
| 测试 | 30%  | 83.3%  | ✅ 通过 |
| 性能 | 20%  | 50.0%  | ⚠️ 勉强 |
```

## 许可证

- 本项目: MIT License
- FlashDB: Apache-2.0 License
