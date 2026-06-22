---
name: smoke-c2rust
description: "Smoke test: 将 FlashDB 的 CRC32 函数转换为 Rust，验证端到端流程"
---

# Skill: Smoke Test — CRC32 函数 C→Rust

## 任务

将 `flashdb/src/fdb_utils.c` 中的 `fdb_calc_crc32` 函数转换为 Rust，创建一个可编译、可测试的最小项目。

## 要转换的 C 代码

```c
static const uint32_t crc32_table[] = {
    0x00000000, 0x77073096, 0xee0e612c, 0x990951ba, 0x076dc419, 0x706af48f,
    0xe963a535, 0x9e6495a3, 0x0edb8832, 0x79dcb8a4, 0xe0d5e91e, 0x97d2d988,
    // ... 完整 256 项表在 flashdb/src/fdb_utils.c 第 21-66 行
    0xb40bbe37, 0xc30c8ea1, 0x5a05df1b, 0x2d02ef8d
};

uint32_t fdb_calc_crc32(uint32_t crc, const void *buf, size_t size)
{
    const uint8_t *p;
    p = (const uint8_t *)buf;
    crc = crc ^ ~0U;
    while (size--) {
        crc = crc32_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ ~0U;
}
```

## 输出要求

在项目根目录创建 `rust-flashdb/` 目录，包含：

### 1. Cargo.toml

```toml
[package]
name = "flashdb-smoke"
version = "0.1.0"
edition = "2021"
```

### 2. src/lib.rs

- 实现 `crc32_table` 常量数组（完整 256 项，从 C 源文件复制）
- 实现 `pub fn calc_crc32(crc: u32, buf: &[u8]) -> u32`
- 算法必须与 C 版本完全一致：初始异或 `!0u32`，查表，最终异或 `!0u32`

### 3. tests/crc32_test.rs

至少包含以下测试用例：
- 空输入: `calc_crc32(0, b"")` 应返回 `0x00000000`
- 已知值: `calc_crc32(0, b"123456789")` 应返回 `0xCBF43926`
- 累积计算: 分两次调用验证 crc 参数的累积语义
- 与 C 版本输出一致的对比测试（用已知输入验证）

## 验证

完成后运行：
```bash
cd rust-flashdb && cargo test
```

确保所有测试通过。
