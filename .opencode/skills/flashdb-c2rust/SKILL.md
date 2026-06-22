---
name: flashdb-c2rust
description: "将 FlashDB C 库完整转换为 Rust 实现，保持功能一致、测试完备、性能不下降"
---

# Skill: FlashDB C→Rust 迁移

## 任务概述

将 `flashdb/` 目录下的 FlashDB C 库（v2.2.99, commit f9d042）完整转换为惯用的 Rust 实现。
输出目录为项目根目录下的 `rust-flashdb/`。

## 源文件清单与职责

| C 源文件 | 行数 | Rust 建议模块 | 职责 |
|----------|------|---------------|------|
| `src/fdb.c` | 118 | `db.rs` | 数据库初始化框架: `_fdb_init_ex`, `_fdb_init_finish`, `_fdb_deinit` |
| `src/fdb_file.c` | 316 | `file.rs` | POSIX 文件 I/O 后端: file-per-sector 模型, LRU fd 缓存 |
| `src/fdb_kvdb.c` | 1945 | `kvdb/mod.rs` | KVDB 完整实现: sector 管理, KV CRUD, GC, 磨损均衡, 缓存 |
| `src/fdb_tsdb.c` | 1118 | `tsdb/mod.rs` | TSDB 完整实现: sector 管理, TSL append/iterate/query, 二分查找 |
| `src/fdb_utils.c` | 312 | `utils.rs` | CRC32, status table 读写, blob 操作, flash 读写调度 |
| `inc/flashdb.h` | — | `lib.rs` | 公共 API 导出 |
| `inc/fdb_def.h` | — | `types.rs` | 所有类型定义 |
| `inc/fdb_low_lvl.h` | — | `low_lvl.rs` | 底层内部 API |

## Rust 项目结构

```
rust-flashdb/
├── Cargo.toml
├── src/
│   ├── lib.rs          # 公共 API, re-exports
│   ├── types.rs        # 所有结构体和枚举定义
│   ├── db.rs           # 数据库初始化框架
│   ├── file.rs         # 文件 I/O 后端
│   ├── kvdb/
│   │   ├── mod.rs      # KVDB 主实现
│   │   ├── sector.rs   # sector 管理
│   │   ├── cache.rs    # KV/sector 缓存
│   │   └── gc.rs       # 垃圾回收
│   ├── tsdb/
│   │   ├── mod.rs      # TSDB 主实现
│   │   ├── sector.rs   # sector 管理
│   │   └── iter.rs     # 迭代器实现
│   └── utils.rs        # CRC32, status table, blob 工具
├── tests/
│   ├── kvdb_test.rs    # KVDB 单元测试 (对应 tests/fdb_kvdb_tc.c)
│   └── tsdb_test.rs    # TSDB 单元测试 (对应 tests/fdb_tsdb_tc.c)
└── benches/
    └── flashdb_bench.rs # 性能基准测试 (对应 tests/benchmark/bench_main.c)
```

## 核心设计要求

### 1. 存储模型
- 使用 `std::fs` 实现 file-per-sector 模式
- 每个 sector 是独立文件: `{db_name}.fdb.{sector_index}`
- 实现 LRU 文件描述符缓存 (容量=2)

### 2. Write Granularity
- 通过 Cargo feature 控制: `write-gran-1`, `write-gran-8`, `write-gran-32`, `write-gran-64`, `write-gran-128`, `write-gran-256`
- 默认 `write-gran-1`
- 影响 status table 编码和对齐计算

### 3. 配置常量 (对应 fdb_def.h)
```
KV_NAME_MAX = 64
KV_CACHE_TABLE_SIZE = 64
SECTOR_CACHE_TABLE_SIZE = 8
FILE_CACHE_TABLE_SIZE = 2
STR_KV_VALUE_MAX_SIZE = 128
GC_EMPTY_SEC_THRESHOLD = 1
```

### 4. Magic Words
- KVDB sector: `0x30424446` ("FDB0")
- KVDB KV: `0x3030564B` ("KV00")
- TSDB sector: `0x304C5354` ("TSL0")

### 5. API 语义保持
必须实现以下公共 API (Rust 风格命名):

**KVDB:**
- `Kvdb::new(name, path, config) -> Result<Self>`
- `kvdb.init() -> Result<()>`
- `kvdb.deinit()`
- `kvdb.control(cmd, arg) -> Result<()>`
- `kvdb.set_kv(key, value_blob) -> Result<()>`
- `kvdb.get_kv(key) -> Option<Blob>`
- `kvdb.del_kv(key) -> Result<()>`
- `kvdb.iter_kv(callback)`
- `kvdb.set_default_kv(defaults)`

**TSDB:**
- `Tsdb::new(name, path, config) -> Result<Self>`
- `tsdb.init() -> Result<()>`
- `tsdb.deinit()`
- `tsdb.control(cmd, arg) -> Result<()>`
- `tsdb.append(blob) -> Result<()>`
- `tsdb.append_with_ts(blob, timestamp) -> Result<()>`
- `tsdb.iter(callback, mode)`
- `tsdb.query_count(from, to) -> u32`
- `tsdb.set_tsl_status(tsl, status) -> Result<()>`
- `tsdb.clean() -> Result<()>`

**工具:**
- `crc32(data) -> u32`
- `blob_make(data) -> Blob`
- `blob_read(blob) -> &[u8]`

### 6. 错误处理
- 使用 `enum FdbError { NotFound, ReadErr, WriteErr, ... }` 替代 C 的 int 错误码
- 实现 `std::error::Error` trait

## 测试要求

### KVDB 测试用例 (对应 fdb_kvdb_tc.c 的 13 个测试)
1. init/deinit 生命周期
2. init 检查 (oldest_addr 验证)
3. 创建/修改/删除 blob 类型 KV
4. 创建/修改/删除 string 类型 KV
5. GC 基础场景 (4-sector 布局)
6. GC 大 KV 跨 sector 场景
7. Scale up (4→8 sectors)
8. 设置默认 KV

### TSDB 测试用例 (对应 fdb_tsdb_tc.c 的 11 个测试)
1. init/deinit
2. clean
3. append
4. 正向迭代
5. 时间范围迭代
6. query count
7. 设置 TSL status
8. 跨 sector 时间范围边界测试
9. 大 blob 测试 (7KB/8KB/9KB)

### 测试辅助
- 实现类似 `test_helpers.h` 的断言宏/函数
- 使用 Rust 标准 `#[test]` 框架
- 每个测试函数独立，可单独运行

## Benchmark 要求

对标 `flashdb/tests/benchmark/bench_main.c` 的指标:
- KVDB: set (string), set (blob), get (string), get (blob), update, iterate, delete
- TSDB: append, iterate, iter_by_time, query_count
- 每项操作运行 3 次取平均
- 使用 `std::time::Instant` 测量 (Rust) vs `clock_gettime(CLOCK_MONOTONIC)` (C)
- 输出每项操作的平均耗时 (微秒)

## 实现优先级

1. **types.rs** — 所有结构体和枚举
2. **utils.rs** — CRC32, status table, blob 工具
3. **file.rs** — 文件 I/O 后端
4. **db.rs** — 初始化框架
5. **kvdb/** — KVDB 完整实现
6. **tsdb/** — TSDB 完整实现
7. **tests/** — 单元测试
8. **benches/** — 性能基准

## 注意事项

- 不要使用 `unsafe` 除非绝对必要 (如 FFI 调用)，且必须加注释说明安全性
- 优先使用 Rust 的 `Result` 和 `Option` 进行错误处理
- 使用 `Vec<u8>` 替代 C 的 `void*` + `size_t` 模式
- 使用 `String` 替代 C 的 `char*`，但注意 KV name 有最大长度限制
- CRC32 实现必须与 C 版本完全一致 (使用相同的多项式和查找表)
- status table 的位操作必须精确匹配 C 实现的行为
