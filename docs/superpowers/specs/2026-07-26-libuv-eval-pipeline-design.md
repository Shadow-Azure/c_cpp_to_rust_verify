# libuv 评测流水线设计

> 日期: 2026-07-26
> 分支: `feat/libuv-eval-pipeline`
> 目标: 新增 libuv 的 C→Rust 转换评测流水线，测试 c2rust skill 的通用性

## 背景与动机

当前评测流水线（`evaluate.yml`）仅覆盖 FlashDB。为验证 c-to-rust skill 在不同类型 C 项目上的通用性，新增一个针对 [libuv](https://github.com/libuv/libuv) 的完整评测流水线。

libuv 与 FlashDB 的关键差异：

| 维度 | FlashDB | libuv |
|---|---|---|
| 领域 | 嵌入式 KV/TS 数据库 | 跨平台异步 I/O 库 |
| 构建系统 | Make | CMake（原生支持 compile_commands.json） |
| API 风格 | 同步数据操作（`fdb_*`） | 事件循环 + 异步 I/O（`uv_*`） |
| 测试框架 | Make + 自定义 | 自定义 runner（`uv_run_tests_a`） |
| 代码规模 | 中等 | 较大（含平台特定代码 `src/unix/`、`src/win/`） |
| 源码引入 | 直接提交在仓库 | Git 子模块 |

## 设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 评测维度 | 完整 4 维度（编译/测试/FFI 等价/性能） | 最全面地测试 skill 通用性 |
| 源码管理 | Git 子模块（固定 tag） | 版本可复现 + 仓库精简 + 本地可浏览 |
| 代码组织 | 平行结构（每项目独立目录） | YAGNI，2 个项目不需要通用框架；不影响 FlashDB 流水线 |

## 文件结构

### 目录重组

将现有 FlashDB 评测文件和新增 libuv 文件按项目组织到独立目录。

```
/
├── flashdb/                          # FlashDB 项目（所有相关文件）
│   ├── source/                       # ← 原 top-level flashdb/ 的 C 源码树
│   ├── ffi-test/                     # ← 原 top-level ffi-test/
│   │   ├── compare_tests.c
│   │   └── Makefile
│   ├── bench/                        # ← 原 bench/rust/flashdb_bench.rs
│   │   └── flashdb_bench.rs
│   ├── scripts/                      # ← 原 scripts/eval-*.sh（去掉 eval- 前缀）
│   │   ├── compile.sh
│   │   ├── tests.sh
│   │   ├── equivalence.sh
│   │   └── performance.sh
│   ├── eval-config.json              # ← 原 top-level
│   └── eval-benchmarks.yml           # ← 原 top-level
│
├── libuv/                            # libuv 项目（所有相关文件）
│   ├── source/                       # git submodule → github.com/libuv/libuv
│   ├── ffi-test/
│   │   ├── compare_tests.c
│   │   └── Makefile
│   ├── bench/
│   │   ├── c/
│   │   │   └── libuv_bench.c         # C 基准测试
│   │   └── libuv_bench.rs            # Rust FFI 基准测试
│   ├── scripts/
│   │   ├── compile.sh
│   │   ├── tests.sh
│   │   ├── equivalence.sh
│   │   └── performance.sh
│   ├── eval-config.json
│   └── eval-benchmarks.yml
│
├── scripts/                          # 跨项目共享脚本（不变）
│   ├── aggregate-score.py
│   ├── analyze-session.py
│   ├── export-all-sessions.py
│   ├── append-incremental-details.py
│   ├── build-c2rust.sh
│   └── server-access.sh
│
├── .github/workflows/
│   ├── evaluate.yml                  # FlashDB（更新路径引用）
│   ├── evaluate-libuv.yml            # NEW: libuv 工作流
│   ├── build-c2rust-release.yml      # 不变
│   └── debug-opencode-session.yml    # 不变
│
├── docker/                           # 不变
├── docs/                             # 不变
└── Dockerfile                        # 不变
```

### 现有文件迁移

| 原路径 | 新路径 |
|---|---|
| `flashdb/*`（C 源码树） | `flashdb/source/*` |
| `ffi-test/` | `flashdb/ffi-test/` |
| `bench/rust/flashdb_bench.rs` | `flashdb/bench/flashdb_bench.rs` |
| `scripts/eval-compile.sh` | `flashdb/scripts/compile.sh` |
| `scripts/eval-tests.sh` | `flashdb/scripts/tests.sh` |
| `scripts/eval-equivalence.sh` | `flashdb/scripts/equivalence.sh` |
| `scripts/eval-performance.sh` | `flashdb/scripts/performance.sh` |
| `eval-config.json` | `flashdb/eval-config.json` |
| `eval-benchmarks.yml` | `flashdb/eval-benchmarks.yml` |

### 设计原则

1. **每个项目目录自包含** — C 源码、FFI 测试、基准测试、评测脚本、配置全在一起
2. **脚本名简化** — 在 `flashdb/scripts/` 下不需要 `eval-` 前缀
3. **共享脚本留在顶层** — `aggregate-score.py`、`analyze-session.py` 等跨项目工具不变
4. **转换输出在 repo 根目录** — `rust-flashdb/` 和 `rust-libuv/` 保持在顶层（CI 产物，不属于项目目录）

## 工作流设计（evaluate-libuv.yml）

### Job 1: convert

`runs-on: ubuntu-24.04`, `environment: production`, `timeout-minutes: 300`

| 步骤 | 说明 | 与 FlashDB 差异 |
|---|---|---|
| Checkout | `submodules: recursive` 拉取 libuv 子模块 | 新增子模块 |
| 安装依赖 | clang, cmake, make, gcc, python3, curl, jq | **新增 cmake，移除 bear** |
| 安装 c2rust | `cargo install c2rust` | 相同 |
| 安装 opencode | `npm install -g opencode-ai` | 相同 |
| 下载 c-to-rust skill | 从 release 下载 v0.13.0 | 相同 |
| 配置 skill | 复制 clang 头文件、agents | 相同 |
| 生成 compile_commands.json | CMake 方式（见下） | **不同：CMake 原生，不用 bear** |
| 修复 -x c 标志 | 强制 C 模式 | 相同逻辑 |
| 运行 OpenCode 转换 | 输出到 `rust-libuv/` | 目录名不同 |
| 验证 cargo test --no-run | 编译测试 | 相同 |
| 上传 artifacts | compile-commands, opencode-sessions, compile-trajectory, rust-libuv | 名称不同 |

**compile_commands.json 生成**（CMake 方式，不需要 bear）：
```bash
cmake -B libuv/source/build -S libuv/source \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DBUILD_TESTING=ON
cp libuv/source/build/compile_commands.json libuv/source/compile_commands.json
```

**OpenCode 转换提示词**：
```
使用 c-to-rust skill 重构 C 语言的 libuv 工程为 rust 语言。注意：
1) PATH 和 LD_LIBRARY_PATH 已配置好，ir/translator/clang++ 直接可用，不需要 Docker。
2) libuv/source/compile_commands.json 已预生成且已添加 -x c 标志（强制 C 模式），不要修改 compile_commands.json。
3) 输出目录必须是 rust-libuv/（不是 libuv-rust/）。
4) 必须按顺序执行 Phase 1、Phase 2、Phase 3、Phase 5（跳过 Phase 4）。
```

### Job 2: evaluate

`needs: convert`, `timeout-minutes: 60`

| 步骤 | 说明 |
|---|---|
| Checkout（含子模块） | 需要 libuv/ 源码做 C 基准 |
| 下载 rust-libuv artifact | |
| 运行 4 个评测脚本 | `libuv/scripts/{compile,tests,equivalence,performance}.sh` |
| 聚合评分 | `scripts/aggregate-score.py` + `libuv/eval-config.json` |
| 分析 session | `scripts/analyze-session.py` |
| 输出报告 | GitHub step summary + artifact |

## 评测脚本设计

### compile.sh / tests.sh

与 FlashDB 版本几乎相同，仅修改：
- `RUST_DIR` 指向 `rust-libuv/`
- `src/*.rs` glob 路径适配

### equivalence.sh — FFI 等价评测

两层评测：

1. **API 符号覆盖** — 解析 `libuv/source/include/uv.h` 中所有 `uv_*` 函数声明，检查 Rust `ffi.rs` 是否导出相同符号
2. **行为等价** — 对确定性函数，编译同一驱动分别链接 C 库和 Rust 库，对比 CASE 行输出

#### 行为测试的 6 个类别

| 类别 | 确定性 | 示例函数 | 归一化 |
|---|---|---|---|
| version_info | 完全确定 | `uv_version()`, `uv_version_string()` | 原始值 |
| sizes | 固定常量 | `uv_loop_size()`, `uv_handle_size(UV_*)`, `uv_req_size(UV_*)` | 原始值 |
| error_strings | 完全确定 | `uv_strerror()`, `uv_err_name()`, `uv_translate_sys_error()` | 原始值 |
| loop_lifecycle | 同步确定 | `uv_loop_init()`, `uv_loop_alive()`, `uv_run()`, `uv_loop_close()` | 原始值 |
| timer_ops | 基本确定 | `uv_timer_init()`, `uv_timer_start()`, `uv_timer_stop()`, `uv_is_active()` | 原始值 |
| system_info | 值可能变化 | `uv_get_total_memory()`, `uv_hrtime()`, `uv_getpid()` | **归一化为 positive/nonzero** |

system_info 归一化示例：
```c
uint64_t mem = uv_get_total_memory();
printf("CASE system_info total_memory PASS %s\n", mem > 0 ? "positive" : "zero");
```

#### 对比方式（与 FlashDB 一致）

1. 构建 C 静态库：`cmake --build libuv/source/build` → `libuv_a.a`
2. 构建 Rust 静态库：`cargo build --release` in `rust-libuv/`
3. 编译 `libuv/ffi-test/compare_tests.c` 分别链接两个库 → `compare_c` + `compare_rust`
4. 运行两个二进制，捕获 CASE 行
5. 排序后 `comm` 对比：匹配 = PASS，差异/缺失 = FAIL

#### 输出格式

```
CASE version_info uv_version PASS 0x013300
CASE sizes loop_size PASS 448
CASE error_strings strerror_einval PASS invalid argument
CASE loop_lifecycle loop_init PASS 0
CASE timer_ops timer_init PASS 0
CASE system_info total_memory PASS positive
```

#### 预计测试用例

| 类别 | 用例数 |
|---|---|
| version_info | 2 |
| sizes | ~15（loop + 6 handle 类型 + 8 req 类型） |
| error_strings | ~10 |
| loop_lifecycle | ~6 |
| timer_ops | ~6 |
| system_info | ~4 |
| **合计** | **~43** |

### performance.sh — 性能评测

#### 基准操作（3 个自定义微基准）

| 操作 | 测什么 | 迭代 |
|---|---|---|
| timer_throughput | 创建 N 个 0ms 定时器 → run loop 直到全部触发 | 10000 |
| loop_overhead | 运行空 loop N 次 | 10000 |
| handle_init | init + close N 个 handle | 10000 |

#### 文件布局

```
libuv/bench/
├── c/
│   └── libuv_bench.c          # C 基准：链接 libuv_a.a
└── libuv_bench.rs             # Rust 基准：注入 rust-libuv/benches/
```

#### 输出格式（与 FlashDB 一致，复用 parse_metrics）

```
  timer_throughput | 10000 ops | 12345.6 us | 810.3 ops/s | 1.23 us/op
  loop_overhead    | 10000 ops | 5678.9 us | 1761.2 ops/s | 0.57 us/op
  handle_init      | 10000 ops | 2345.6 us | 4263.5 ops/s | 0.23 us/op
```

#### 执行流程

1. **C 基线**：编译 `libuv/bench/c/libuv_bench.c` 链接 `libuv_a.a` → 运行 → 解析
2. **Rust 基准**：注入 `libuv/bench/libuv_bench.rs` 到 `rust-libuv/benches/` → `cargo bench --bench libuv_bench` → 解析
3. **对比**：每个操作计算 `rust_us_per_op / c_us_per_op`，≤ 1.5x 为通过

### 评分配置

```json
// libuv/eval-config.json — 与 FlashDB 相同
{
  "weights": { "compile": 0.40, "tests": 0.20, "equivalence": 0.25, "performance": 0.15 }
}
```

## 影响分析

### 需要更新的路径引用（FlashDB 迁移）

| 文件 | 更新内容 |
|---|---|
| `evaluate.yml` | `flashdb/` → `flashdb/source/`；脚本路径 → `flashdb/scripts/*.sh`；配置 → `flashdb/eval-config.json` |
| `flashdb/scripts/*.sh` | `flashdb/inc/flashdb.h` → `flashdb/source/inc/flashdb.h`；其他 flashdb 路径同步 |
| `flashdb/ffi-test/Makefile` | `../flashdb/` → `../source/` |
| `scripts/aggregate-score.py` | 现有配置路径逻辑有 bug：`Path("/tmp/compile-result.json").parent.parent` = `/`，导致从未读取 `eval-config.json`，一直用硬编码默认权重。改为接受配置文件路径作为显式第 6 参数（`aggregate-score.py <compile> <test> <equiv> <perf> <report> <config>`），两套流水线分别传入 `flashdb/eval-config.json` 和 `libuv/eval-config.json` |
| `flashdb/scripts/performance.sh`（原 `eval-performance.sh`） | `$ROOT_DIR/eval-benchmarks.yml` → `$ROOT_DIR/flashdb/eval-benchmarks.yml` |

### 风险

1. **FlashDB 流水线回归** — 移动文件和更新路径可能引入错误。缓解：所有 `git mv` 保留历史，路径更新后仔细检查
2. **libuv 子模块版本** — 需要固定到具体 tag（实现时确认最新稳定版）
3. **c2rust 对 libuv 的转换效果未知** — libuv 平台特定代码和宏可能超出 skill 处理能力。这正是测试目标
4. **性能基准的确定性** — 异步 I/O 操作有噪声。缓解：使用大量迭代取均值，放宽容差
