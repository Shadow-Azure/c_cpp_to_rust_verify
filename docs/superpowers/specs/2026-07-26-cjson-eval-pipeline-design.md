# cJSON 评测流水线设计

> 日期: 2026-07-26
> 分支: `feat/cjson-eval`
> 目标: 新增 cJSON 的 C→Rust 转换评测流水线，进一步测试 c2rust skill 的通用性

## 背景与动机

当前评测流水线覆盖 FlashDB 与 libuv 两个项目。为继续验证 c-to-rust skill 在不同形态 C 项目上的通用性，新增针对 [cJSON](https://github.com/DaveGamble/cJSON) 的完整评测流水线。

cJSON 与现有项目的关键差异：

| 维度 | FlashDB | libuv | cJSON |
|---|---|---|---|
| 领域 | 嵌入式 KV/TS 数据库 | 跨平台异步 I/O 库 | JSON 解析/生成库 |
| 构建系统 | Make | CMake | CMake |
| C 标准 | gnu99 | c11 + atomics（需预处理） | **C89/C90（纯）** |
| 源码规模 | 中（多模块） | 大（含 `unix/`、`win/` 平台代码） | **小（单文件 `cJSON.c`，~3000 行）** |
| 系统依赖 | 无 | `-lpthread -ldl -lrt` | **无（纯计算）** |
| 测试框架 | Make + 自定义 | 自定义 runner | CMake +CTest |
| 源码引入 | 直接提交 | Git 子模块（master） | Git 子模块（**v1.7.18 tag**） |

cJSON 是三者中**结构最简单**的（单文件、纯 C89、无平台代码、无原子操作），因此流水线比 libuv 更精简：无需 `preprocess_atomics.py`、无需 `/test/` 路径过滤、无需系统库链接。

## 设计决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 评测维度 | 完整 4 维度（编译/测试/FFI 等价/性能） | 与 FlashDB / libuv 对齐，便于横向对比 |
| FFI 覆盖范围 | **完整覆盖** cJSON_* 公共 API（~40 函数，10 类） | 测试 skill 在完整 API 表面上的能力，不止冒烟 |
| 性能指标数 | 4 个（parse/print/traverse） | 与 libuv 的 3 指标规模相当，聚焦 cJSON 核心操作 |
| 源码版本 | 子模块锁 `v1.7.18` tag | 最新稳定版，保证可复现 |
| 运行环境 | ubuntu-22.04 + self-hosted runner（production） | 与 libuv 对齐；cJSON 无 24.04 特殊需求 |
| CMake 选项 | `BUILD_TESTING=OFF` | 单 .c 文件，避免 test 模块混入 compile_commands |
| compile_commands 修复 | 仅添加 `-x c -std=gnu99` | 无需过滤，无需 atomics 预处理 |

## 文件结构

完全镜像 libuv 目录布局：

```
/
├── cjson/                            # cJSON 项目（所有相关文件）
│   ├── source/                       # git submodule → DaveGamble/cJSON.git @ v1.7.18
│   ├── ffi-test/
│   │   ├── compare_tests.c           # FFI 等价驱动（~40 函数，10 类）
│   │   └── Makefile                  # 构建 libcjson.a + compare_c + compare_rust
│   ├── bench/
│   │   ├── c/
│   │   │   └── cjson_bench.c         # C 基准
│   │   └── cjson_bench.rs            # Rust 基准（由 performance.sh 注入 crate）
│   ├── scripts/
│   │   ├── compile.sh
│   │   ├── tests.sh
│   │   ├── equivalence.sh
│   │   └── performance.sh
│   ├── eval-config.json
│   └── eval-benchmarks.yml
│
└── .github/workflows/
    └── evaluate-cjson.yml            # convert job + evaluate job
```

### 与 libuv 模板的删减

| 删除项 | 原因 |
|---|---|
| `scripts/preprocess_atomics.py` | cJSON 是纯 C89，无 `_Atomic`、无 `atomic_*` 调用 |
| Makefile 中的 `$(SYSLIBS)` | cJSON 单线程纯计算，无系统库依赖 |
| compile_commands.json 的 `/test/` 过滤逻辑 | 用 `BUILD_TESTING=OFF` 替代，源头避免 |

## workflow 设计（`evaluate-cjson.yml`）

镜像 `evaluate-libuv.yml`，包含两个 job：`convert` 与 `evaluate`。

### Job 1: convert

| 步骤 | 关键差异点 |
|---|---|
| `runs-on` | ubuntu-22.04（同 libuv） |
| 安装依赖 | 同 libuv：`clang cmake make gcc bc python3 jq libclang-dev` |
| 缓存 + 下载 skill | v0.13.0，同 libuv |
| 生成 compile_commands.json | `cmake -B build -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DBUILD_TESTING=OFF -DCMAKE_C_COMPILER=clang` |
| 修复 compile_commands.json | 仅添加 `-x c` 与 `-std=gnu99`（不过滤、不处理 atomics） |
| 跳过 preprocess_atomics | cJSON 无需 |
| Run OpenCode conversion | 见下方提示词 |
| 后续上传 artifacts | 同 libuv：rust-cjson/、opencode-sessions-cjson/、compile-trajectory-cjson |

### OpenCode 转换提示词

```
使用 c-to-rust skill 重构 C 语言的 cjson 工程为 rust 语言。注意：
1) PATH 和 LD_LIBRARY_PATH 已配置好，ir/translator/clang++ 直接可用，不需要 Docker。
2) cjson/source/compile_commands.json 已预生成（-x c -std=gnu99），不要修改。
3) 输出目录必须是 rust-cjson/（不是 cjson-rust/）。
4) 必须按顺序执行 Phase 1、Phase 2、Phase 3、Phase 5（跳过 Phase 4）。
5) 如果 c2rust 因模块名 panic（例如 cJSON 模块名大小写问题），
   将输出文件重命名（如 cJSON_.rs）并在 lib.rs 用 #[path="..."] 或 mod 显式声明，然后继续；
   其他 panic 则跳过该文件不要反复调试。
```

### Job 2: evaluate

| 步骤 | 与 libuv 差异 |
|---|---|
| 安装依赖 | 同 libuv（无需 cmake 在 evaluate，但保留以防） |
| 运行 4 个评测脚本 | 路径前缀从 `libuv/scripts/` 改为 `cjson/scripts/` |
| 聚合评分 | `eval-config.json` 路径改为 `cjson/eval-config.json` |
| artifact 命名 | 加 `-cjson` 后缀，避免与其它项目冲突 |

## FFI 等价测试设计

### 双二进制对比模型

`compare_tests.c` 调用 cJSON 原始符号名（`cJSON_Parse`、`cJSON_GetObjectItem` 等）。harness 将同一个驱动编译两次：

- `compare_c`：链接 C 参考静态库 `libcjson.a`
- `compare_rust`：链接 Rust 静态库（ffi.rs 必须导出相同 `#[no_mangle] extern "C"` 符号）

每个 case 输出一行：`CASE <category> <case_id> <expected_output>`，由 `equivalence.sh` 做排序 + `comm` 三路 diff。

### 10 个分类（覆盖完整 cJSON_* API）

| 分类 | 覆盖 API |
|---|---|
| `version_info` | `cJSON_Version` |
| `parse_basic` | `cJSON_Parse`, `cJSON_ParseWithLength`, `cJSON_ParseWithOpts` |
| `parse_errors` | `cJSON_GetErrorPtr` + 对坏 JSON 调 `cJSON_IsInvalid` |
| `print` | `cJSON_Print`, `cJSON_PrintUnformatted`, `cJSON_PrintBuffered`, `cJSON_PrintPreallocated` |
| `type_check` | `IsObject/Array/String/Number/Bool/Null/Invalid/True/False/Raw` |
| `access` | `GetObjectItem`, `GetObjectItemCaseSensitive`, `GetArrayItem`, `GetStringValue`, `GetNumberValue`, `HasObjectItem`, `GetArraySize` |
| `create` | `CreateObject/Array/String/Number/Bool/Null/Reference/Raw` |
| `add` | `AddItemToObject/Array` + `AddNullToObject` 等快捷函数族 |
| `modify` | `ReplaceItemInObject/Array`, `SetNumberValue`, `SetValuestring` |
| `delete` | `Delete`, `DetachItemViaPointer/FromArray/FromObject`, `DeleteItemFromObject/Array` |

**API 提取正则**：从 `cJSON.h` 中匹配 `cJSON_[a-zA-Z0-9_]+\s*\(`（注意 cJSON 函数名含大写 `JSON`，不同于 libuv 的纯小写 `uv_*`）。

**实现目标**：40 个公共函数中实现 ≥30 个。

### Makefile 差异

```makefile
ROOT_DIR   := $(shell cd ../.. && pwd)
CJSON_DIR  := $(ROOT_DIR)/cjson/source
BUILD_DIR  := build

CC         ?= cc
CFLAGS     := -O0 -g3 -Wall -Wno-format -I$(CJSON_DIR)

# cJSON 无系统库依赖
SYSLIBS    :=

c-lib:
	cd $(CJSON_DIR) && cmake -B build -DBUILD_TESTING=OFF -DCMAKE_BUILD_TYPE=Release
	cmake --build $(CJSON_DIR)/build --config Release
	cp $(CJSON_DIR)/build/libcjson.a $(BUILD_DIR)/libcjson_c.a
```

## 性能基准设计

C 和 Rust 基准输出相同格式（与 libuv 对齐）：

```
   <name>             | <N> ops | <total> us | <throughput> ops/s | <us>/op
```

由 `performance.sh` 用同一个 parser 提取 `us/op` 作为指标值。

### 4 个指标

| 指标 | 描述 |
|---|---|
| `parse_small` | 扁平 object `{"name":"cJSON","ver":1.7,"ok":true,...}`，10000 次迭代 |
| `parse_large` | 深嵌套/大数组（构造 1000 元素数组），1000 次迭代 |
| `print_unformatted` | 对 `parse_large` 结果做 `cJSON_PrintUnformatted` 往返，1000 次 |
| `traverse` | 遍历 1000 元素数组并累加数值字段，1000 次 |

`eval-config.json` 中 `max_regression_ratio: 1.5`，与 libuv 一致。

## eval-config.json

```json
{
  "weights": {
    "compile": 0.40,
    "test": 0.20,
    "equivalence": 0.25,
    "performance": 0.15
  },
  "compile": {
    "check_warnings": false
  },
  "test": {
    "require_all_pass": true,
    "coverage_threshold": 0.0
  },
  "performance": {
    "max_regression_ratio": 1.5,
    "metrics": [
      "parse_small",
      "parse_large",
      "print_unformatted",
      "traverse"
    ]
  }
}
```

## 风险与未知

1. **模块名 `cJSON`**：c2rust 通常保留文件名 `cJSON.rs`。`mod cJSON;` 在 Rust 中合法（非关键字），但需确保 `lib.rs` 有对应 `mod` 声明。提示词第 5 条已预防。

2. **Rust crate 名**：c2rust 生成的 `Cargo.toml` `[package] name` 可能是 `cjson` / `c_json` / `cJSON`。`equivalence.sh` 在 `target/release/` 下尝试多种猜测：`lib{cjson,c_json,cJSON,libcjson}.{a,rlib}`。

3. **`CJSON_PUBLIC` 宏**：cJSON.h 用 `CJSON_PUBLIC(type) type func(...)` 宏包裹声明。`equivalence.sh` 的 API 提取正则需匹配 `cJSON_[a-zA-Z0-9_]+\(`（含大写）。

4. **c2rust panic 处理**：`cJSON.c` 含较多指针算术与手写双向链表。如某段 panic，按既定策略跳过、不反复调试。

5. **首次运行**：v0.13.0 skill 从未见过 cJSON 形态。第一次 eval 跑完才能知道真实编译率，可能需要 1-2 轮迭代调提示词。

## 实施步骤

1. 切分支 `feat/cjson-eval`（基于 main）
2. 添加 git submodule：`cjson/source` → cJSON v1.7.18
3. 写 15 个新文件（脚本 + 配置 + bench + ffi-test + workflow）
4. 本地校验：
   - `bash -n` 检查所有 shell 脚本语法
   - `python3 -m json.tool` 校验 JSON
   - YAML lint 校验 workflow
5. 提交并推送，触发首次 workflow_dispatch 验证
