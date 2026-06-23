/*
 * rust_ffi.h — Rust FFI 函数声明
 *
 * 这些函数由 Rust 转换版 FlashDB (rust-flashdb/src/ffi.rs) 实现，
 * 用于与 C 原版进行功能等价对比测试。
 */

#ifndef _RUST_FFI_H_
#define _RUST_FFI_H_

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>  /* ssize_t */

#ifdef __cplusplus
extern "C" {
#endif

/* ============================================================
 * 不透明句柄
 * ============================================================ */
typedef struct fdb_rust_kvdb *fdb_rust_kvdb_t;
typedef struct fdb_rust_tsdb *fdb_rust_tsdb_t;

/* ============================================================
 * 错误码 (与 C 版 fdb_err_t 对齐)
 * ============================================================ */
#define FDB_RUST_OK           0
#define FDB_RUST_ERASE_ERR   -1
#define FDB_RUST_READ_ERR    -2
#define FDB_RUST_WRITE_ERR   -3
#define FDB_RUST_NOT_FOUND   -4

/* ============================================================
 * CRC32
 * ============================================================ */
uint32_t fdb_rust_calc_crc32(uint32_t crc, const uint8_t *buf, size_t size);

/* ============================================================
 * KVDB — Key-Value Database
 * ============================================================ */

/* 初始化 KVDB (file mode, 4 sectors × 4096 bytes) */
fdb_rust_kvdb_t fdb_rust_kvdb_init(const char *name, const char *path);

/* 反初始化 */
void fdb_rust_kvdb_deinit(fdb_rust_kvdb_t db);

/* 设置字符串 KV: key → value */
int fdb_rust_kv_set(fdb_rust_kvdb_t db, const char *key, const char *value);

/* 获取字符串 KV: 返回 Rust 分配的字符串，调用者必须用 fdb_rust_free_string 释放 */
char *fdb_rust_kv_get(fdb_rust_kvdb_t db, const char *key);

/* 释放 Rust 分配的字符串 */
void fdb_rust_free_string(char *s);

/* 删除 KV */
int fdb_rust_kv_del(fdb_rust_kvdb_t db, const char *key);

/* 设置 blob KV */
int fdb_rust_kv_set_blob(fdb_rust_kvdb_t db, const char *key,
                          const uint8_t *data, size_t len);

/* 获取 blob KV: 返回实际读取字节数, <0 表示错误 */
ssize_t fdb_rust_kv_get_blob(fdb_rust_kvdb_t db, const char *key,
                              uint8_t *buf, size_t buf_len);

/* ============================================================
 * TSDB — Time Series Database
 * ============================================================ */

/* 初始化 TSDB (file mode, 16 sectors × 4096 bytes, max_len=128) */
fdb_rust_tsdb_t fdb_rust_tsdb_init(const char *name, const char *path, size_t max_len);

/* 反初始化 */
void fdb_rust_tsdb_deinit(fdb_rust_tsdb_t db);

/* 追加 TSL 记录 (带时间戳) */
int fdb_rust_tsl_append(fdb_rust_tsdb_t db, const uint8_t *data,
                         size_t len, uint32_t timestamp);

/* 按时间范围查询 TSL 数量 */
size_t fdb_rust_tsl_query_count(fdb_rust_tsdb_t db, uint32_t from, uint32_t to);

/* 清空所有 TSL */
void fdb_rust_tsl_clean(fdb_rust_tsdb_t db);

#ifdef __cplusplus
}
#endif

#endif /* _RUST_FFI_H_ */
