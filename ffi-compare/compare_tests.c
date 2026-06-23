/*
 * compare_tests.c — FFI 功能等价对比测试
 *
 * 同时调用 C 原版和 Rust 转换版的 FlashDB API，对比结果是否一致。
 * 以 C 为基准，验证 Rust 实现的功能等价性。
 *
 * 编译: cc -o compare_tests compare_tests.c libflashdb_c.a libflashdb_rust.a -lpthread
 * 运行: ./compare_tests
 *
 * 输出格式 (stdout):
 *   测试名称 PASS/FAIL [详细信息]
 *
 * 最终统计:
 *   PASSED: N  FAILED: N  TOTAL: N
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>

/* C 原版 FlashDB */
#include <flashdb.h>
#include <fdb_cfg.h>

/* Rust FFI */
#include "rust_ffi.h"

/* ============================================================
 * 测试框架
 * ============================================================ */

static int g_passed = 0;
static int g_failed = 0;
static int g_total  = 0;

#define TEST_BEGIN(name) do { \
    g_total++; \
    printf("  %-45s ", name); \
    fflush(stdout); \
} while(0)

#define TEST_PASS() do { \
    g_passed++; \
    printf("PASS\n"); \
} while(0)

#define TEST_FAIL(msg) do { \
    g_failed++; \
    printf("FAIL: %s\n", msg); \
} while(0)

#define ASSERT_EQ_INT(a, b, msg) do { \
    if ((a) != (b)) { TEST_FAIL(msg); return; } \
} while(0)

#define ASSERT_EQ_STR(a, b, msg) do { \
    if (strcmp((a), (b)) != 0) { TEST_FAIL(msg); return; } \
} while(0)

#define ASSERT_NULL(p, msg) do { \
    if ((p) != NULL) { TEST_FAIL(msg); return; } \
} while(0)

#define ASSERT_NOT_NULL(p, msg) do { \
    if ((p) == NULL) { TEST_FAIL(msg); return; } \
} while(0)

#define ASSERT_EQ_BUF(a, b, len, msg) do { \
    if (memcmp((a), (b), (len)) != 0) { TEST_FAIL(msg); return; } \
} while(0)

/* ============================================================
 * 辅助函数
 * ============================================================ */

static void rmrf(const char *path) {
    char cmd[512];
    snprintf(cmd, sizeof(cmd), "rm -rf %s", path);
    system(cmd);
}

static void ensure_dir(const char *path) {
    mkdir(path, 0755);
}

/* ============================================================
 * CRC32 测试 (3 cases)
 * ============================================================ */

static void test_crc32_empty(void) {
    TEST_BEGIN("crc32_empty");
    uint32_t c_val   = fdb_calc_crc32(0, (const uint8_t *)"", 0);
    uint32_t rust_val = fdb_rust_calc_crc32(0, (const uint8_t *)"", 0);
    ASSERT_EQ_INT(c_val, rust_val, "CRC32 of empty input mismatch");
    TEST_PASS();
}

static void test_crc32_standard(void) {
    TEST_BEGIN("crc32_standard");
    const char *data = "123456789";
    uint32_t c_val   = fdb_calc_crc32(0, (const uint8_t *)data, 9);
    uint32_t rust_val = fdb_rust_calc_crc32(0, (const uint8_t *)data, 9);
    ASSERT_EQ_INT(c_val, rust_val, "CRC32 of '123456789' mismatch");
    /* 已知标准值 */
    ASSERT_EQ_INT(c_val, 0xCBF43926, "CRC32 standard value incorrect");
    TEST_PASS();
}

static void test_crc32_cumulative(void) {
    TEST_BEGIN("crc32_cumulative");
    const char *part1 = "Hello, ";
    const char *part2 = "World!";
    /* 一次性计算 */
    char full[64];
    snprintf(full, sizeof(full), "%s%s", part1, part2);
    uint32_t c_full = fdb_calc_crc32(0, (const uint8_t *)full, strlen(full));
    /* 分段计算 */
    uint32_t c_step = fdb_calc_crc32(0, (const uint8_t *)part1, strlen(part1));
    c_step = fdb_rust_calc_crc32(c_step, (const uint8_t *)part2, strlen(part2));
    /* Rust 分段计算 */
    uint32_t rust_step = fdb_rust_calc_crc32(0, (const uint8_t *)part1, strlen(part1));
    rust_step = fdb_rust_calc_crc32(rust_step, (const uint8_t *)part2, strlen(part2));
    ASSERT_EQ_INT(c_full, rust_step, "Cumulative CRC32 mismatch: C full vs Rust step");
    TEST_PASS();
}

/* ============================================================
 * KVDB 测试 (8 cases)
 * ============================================================ */

#define KVDB_NAME  "cmp_kvdb"
#define KVDB_PATH  "/tmp/cmp_kvdb_data"

static void test_kv_init_deinit(void) {
    TEST_BEGIN("kv_init_deinit");
    /* C */
    ensure_dir(KVDB_PATH);
    struct fdb_kvdb c_db;
    fdb_err_t c_err = fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    /* Rust */
    fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
    ASSERT_NOT_NULL(r_db, "Rust kvdb_init returned NULL");
    /* 对比: C 的 init 成功则 Rust 也应成功 */
    if (c_err == FDB_NO_ERR) {
        fdb_kvdb_deinit(&c_db);
        fdb_rust_kvdb_deinit(r_db);
        rmrf(KVDB_PATH);
        TEST_PASS();
    } else {
        fdb_rust_kvdb_deinit(r_db);
        rmrf(KVDB_PATH);
        TEST_FAIL("C kvdb_init failed");
    }
}

static void test_kv_set_get_string(void) {
    TEST_BEGIN("kv_set_get_string");
    ensure_dir(KVDB_PATH);
    /* C */
    struct fdb_kvdb c_db;
    fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_err_t c_set = fdb_kv_set(&c_db, "key1", "hello");
    char *c_get = fdb_kv_get(&c_db, "key1");
    /* Rust */
    fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
    int r_set = fdb_rust_kv_set(r_db, "key1", "hello");
    char *r_get = fdb_rust_kv_get(r_db, "key1");
    /* 对比 */
    ASSERT_EQ_INT(c_set, r_set, "set return code mismatch");
    ASSERT_NOT_NULL(c_get, "C kv_get returned NULL");
    ASSERT_NOT_NULL(r_get, "Rust kv_get returned NULL");
    ASSERT_EQ_STR(c_get, r_get, "get value mismatch");
    /* 清理 */
    fdb_rust_free_string(r_get);
    fdb_kvdb_deinit(&c_db);
    fdb_rust_kvdb_deinit(r_db);
    rmrf(KVDB_PATH);
    TEST_PASS();
}

static void test_kv_set_get_blob(void) {
    TEST_BEGIN("kv_set_get_blob");
    ensure_dir(KVDB_PATH);
    uint8_t blob_data[] = {0x01, 0x02, 0x03, 0x04, 0x05};
    size_t blob_len = sizeof(blob_data);
    /* C */
    struct fdb_kvdb c_db;
    fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    struct fdb_blob c_blob;
    fdb_blob_make(&c_blob, blob_data, blob_len);
    fdb_err_t c_set = fdb_kv_set_blob(&c_db, "blob1", &c_blob);
    uint8_t c_buf[64] = {0};
    struct fdb_blob c_rblob;
    fdb_blob_make(&c_rblob, c_buf, sizeof(c_buf));
    size_t c_read = fdb_kv_get_blob(&c_db, "blob1", &c_rblob);
    /* Rust */
    fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
    int r_set = fdb_rust_kv_set_blob(r_db, "blob1", blob_data, blob_len);
    uint8_t r_buf[64] = {0};
    ssize_t r_read = fdb_rust_kv_get_blob(r_db, "blob1", r_buf, sizeof(r_buf));
    /* 对比 */
    ASSERT_EQ_INT(c_set, r_set, "set_blob return code mismatch");
    ASSERT_EQ_INT((int)c_read, (int)r_read, "get_blob read size mismatch");
    ASSERT_EQ_BUF(blob_data, r_buf, blob_len, "get_blob data mismatch");
    /* 清理 */
    fdb_kvdb_deinit(&c_db);
    fdb_rust_kvdb_deinit(r_db);
    rmrf(KVDB_PATH);
    TEST_PASS();
}

static void test_kv_overwrite(void) {
    TEST_BEGIN("kv_overwrite");
    ensure_dir(KVDB_PATH);
    /* C */
    struct fdb_kvdb c_db;
    fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_kv_set(&c_db, "k", "v1");
    fdb_kv_set(&c_db, "k", "v2");
    char *c_get = fdb_kv_get(&c_db, "k");
    /* Rust */
    fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
    fdb_rust_kv_set(r_db, "k", "v1");
    fdb_rust_kv_set(r_db, "k", "v2");
    char *r_get = fdb_rust_kv_get(r_db, "k");
    /* 对比 */
    ASSERT_NOT_NULL(c_get, "C get after overwrite NULL");
    ASSERT_NOT_NULL(r_get, "Rust get after overwrite NULL");
    ASSERT_EQ_STR(c_get, r_get, "overwrite value mismatch");
    /* 清理 */
    fdb_rust_free_string(r_get);
    fdb_kvdb_deinit(&c_db);
    fdb_rust_kvdb_deinit(r_db);
    rmrf(KVDB_PATH);
    TEST_PASS();
}

static void test_kv_delete(void) {
    TEST_BEGIN("kv_delete");
    ensure_dir(KVDB_PATH);
    /* C */
    struct fdb_kvdb c_db;
    fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_kv_set(&c_db, "del_me", "value");
    fdb_err_t c_del = fdb_kv_del(&c_db, "del_me");
    char *c_get = fdb_kv_get(&c_db, "del_me");
    /* Rust */
    fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
    fdb_rust_kv_set(r_db, "del_me", "value");
    int r_del = fdb_rust_kv_del(r_db, "del_me");
    char *r_get = fdb_rust_kv_get(r_db, "del_me");
    /* 对比 */
    ASSERT_EQ_INT(c_del, r_del, "del return code mismatch");
    ASSERT_NULL(c_get, "C get after del not NULL");
    ASSERT_NULL(r_get, "Rust get after del not NULL");
    /* 清理 */
    fdb_kvdb_deinit(&c_db);
    fdb_rust_kvdb_deinit(r_db);
    rmrf(KVDB_PATH);
    TEST_PASS();
}

static void test_kv_nonexistent(void) {
    TEST_BEGIN("kv_nonexistent");
    ensure_dir(KVDB_PATH);
    /* C */
    struct fdb_kvdb c_db;
    fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    char *c_get = fdb_kv_get(&c_db, "no_such_key");
    /* Rust */
    fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
    char *r_get = fdb_rust_kv_get(r_db, "no_such_key");
    /* 对比: 两边都应返回 NULL */
    ASSERT_NULL(c_get, "C get nonexistent not NULL");
    ASSERT_NULL(r_get, "Rust get nonexistent not NULL");
    /* 清理 */
    fdb_kvdb_deinit(&c_db);
    fdb_rust_kvdb_deinit(r_db);
    rmrf(KVDB_PATH);
    TEST_PASS();
}

static void test_kv_multiple_keys(void) {
    TEST_BEGIN("kv_multiple_keys");
    ensure_dir(KVDB_PATH);
    /* C */
    struct fdb_kvdb c_db;
    fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_kv_set(&c_db, "alpha", "1");
    fdb_kv_set(&c_db, "beta",  "2");
    fdb_kv_set(&c_db, "gamma", "3");
    char *c_a = fdb_kv_get(&c_db, "alpha");
    char *c_b = fdb_kv_get(&c_db, "beta");
    char *c_g = fdb_kv_get(&c_db, "gamma");
    /* Rust */
    fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
    fdb_rust_kv_set(r_db, "alpha", "1");
    fdb_rust_kv_set(r_db, "beta",  "2");
    fdb_rust_kv_set(r_db, "gamma", "3");
    char *r_a = fdb_rust_kv_get(r_db, "alpha");
    char *r_b = fdb_rust_kv_get(r_db, "beta");
    char *r_g = fdb_rust_kv_get(r_db, "gamma");
    /* 对比 */
    ASSERT_EQ_STR(c_a, r_a, "alpha mismatch");
    ASSERT_EQ_STR(c_b, r_b, "beta mismatch");
    ASSERT_EQ_STR(c_g, r_g, "gamma mismatch");
    /* 清理 */
    fdb_rust_free_string(r_a);
    fdb_rust_free_string(r_b);
    fdb_rust_free_string(r_g);
    fdb_kvdb_deinit(&c_db);
    fdb_rust_kvdb_deinit(r_db);
    rmrf(KVDB_PATH);
    TEST_PASS();
}

static void test_kv_reboot_persistence(void) {
    TEST_BEGIN("kv_reboot_persistence");
    ensure_dir(KVDB_PATH);
    /* 写入 */
    {
        struct fdb_kvdb c_db;
        fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
        fdb_kv_set(&c_db, "persist", "data123");
        fdb_kvdb_deinit(&c_db);
    }
    /* C 重新读取 */
    char *c_get;
    {
        struct fdb_kvdb c_db;
        fdb_kvdb_init(&c_db, KVDB_NAME, KVDB_PATH, NULL, NULL);
        c_get = fdb_kv_get(&c_db, "persist");
        fdb_kvdb_deinit(&c_db);
    }
    /* Rust 写入 + 重新读取 */
    {
        fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
        fdb_rust_kv_set(r_db, "persist", "data123");
        fdb_rust_kvdb_deinit(r_db);
    }
    char *r_get;
    {
        fdb_rust_kvdb_t r_db = fdb_rust_kvdb_init(KVDB_NAME, KVDB_PATH);
        r_get = fdb_rust_kv_get(r_db, "persist");
        fdb_rust_kvdb_deinit(r_db);
    }
    /* 对比 */
    ASSERT_NOT_NULL(c_get, "C persist get NULL after reboot");
    ASSERT_NOT_NULL(r_get, "Rust persist get NULL after reboot");
    ASSERT_EQ_STR(c_get, r_get, "persist value mismatch after reboot");
    /* 清理 */
    fdb_rust_free_string(r_get);
    rmrf(KVDB_PATH);
    TEST_PASS();
}

/* ============================================================
 * TSDB 测试 (7 cases)
 * ============================================================ */

#define TSDB_NAME  "cmp_tsdb"
#define TSDB_PATH  "/tmp/cmp_tsdb_data"

static uint32_t g_ts_counter = 0;
static uint32_t test_get_time(void) {
    return ++g_ts_counter;
}

static void test_ts_init_deinit(void) {
    TEST_BEGIN("ts_init_deinit");
    ensure_dir(TSDB_PATH);
    /* C */
    struct fdb_tsdb c_db;
    fdb_err_t c_err = fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    /* Rust */
    fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
    ASSERT_NOT_NULL(r_db, "Rust tsdb_init returned NULL");
    if (c_err == FDB_NO_ERR) {
        fdb_tsdb_deinit(&c_db);
        fdb_rust_tsdb_deinit(r_db);
        rmrf(TSDB_PATH);
        TEST_PASS();
    } else {
        fdb_rust_tsdb_deinit(r_db);
        rmrf(TSDB_PATH);
        TEST_FAIL("C tsdb_init failed");
    }
}

static void test_tsl_append(void) {
    TEST_BEGIN("tsl_append");
    ensure_dir(TSDB_PATH);
    g_ts_counter = 100;
    /* C */
    struct fdb_tsdb c_db;
    fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    uint8_t data[] = {0xAA, 0xBB, 0xCC};
    struct fdb_blob c_blob;
    fdb_blob_make(&c_blob, data, sizeof(data));
    fdb_err_t c_err = fdb_tsl_append(&c_db, &c_blob);
    fdb_tsdb_deinit(&c_db);
    /* Rust */
    fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
    int r_err = fdb_rust_tsl_append(r_db, data, sizeof(data), 101);
    fdb_rust_tsdb_deinit(r_db);
    /* 对比: 两边都应成功 */
    ASSERT_EQ_INT(c_err, r_err, "tsl_append return code mismatch");
    rmrf(TSDB_PATH);
    TEST_PASS();
}

static void test_tsl_append_multiple(void) {
    TEST_BEGIN("tsl_append_multiple");
    ensure_dir(TSDB_PATH);
    /* C */
    struct fdb_tsdb c_db;
    fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    for (int i = 0; i < 5; i++) {
        uint8_t data[4] = {i, i+1, i+2, i+3};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append(&c_db, &blob);
    }
    /* 使用 fdb_tsl_clean 后重新计数 */
    fdb_tsl_clean(&c_db);
    for (int i = 0; i < 5; i++) {
        uint8_t data[4] = {i, i+1, i+2, i+3};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append(&c_db, &blob);
    }
    size_t c_count = fdb_tsl_query_count(&c_db, 0, 0xFFFFFFFF, FDB_TSL_WRITE);
    fdb_tsdb_deinit(&c_db);
    /* Rust */
    fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
    fdb_rust_tsl_clean(r_db);
    for (int i = 0; i < 5; i++) {
        uint8_t data[4] = {i, i+1, i+2, i+3};
        fdb_rust_tsl_append(r_db, data, sizeof(data), 200 + i);
    }
    size_t r_count = fdb_rust_tsl_query_count(r_db, 0, 0xFFFFFFFF);
    fdb_rust_tsdb_deinit(r_db);
    /* 对比 */
    ASSERT_EQ_INT((int)c_count, (int)r_count, "append_multiple count mismatch");
    rmrf(TSDB_PATH);
    TEST_PASS();
}

static void test_tsl_query_count(void) {
    TEST_BEGIN("tsl_query_count");
    ensure_dir(TSDB_PATH);
    /* C: 追加 5 条记录 (时间戳 10,20,30,40,50) */
    struct fdb_tsdb c_db;
    fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    fdb_tsl_clean(&c_db);
    for (int i = 0; i < 5; i++) {
        uint8_t data[2] = {i, 0};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append_with_ts(&c_db, &blob, (i+1)*10);
    }
    /* 查询时间范围 [15, 45] 应返回 3 条 (20,30,40) */
    size_t c_count = fdb_tsl_query_count(&c_db, 15, 45, FDB_TSL_WRITE);
    fdb_tsdb_deinit(&c_db);
    /* Rust */
    fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
    fdb_rust_tsl_clean(r_db);
    for (int i = 0; i < 5; i++) {
        uint8_t data[2] = {i, 0};
        fdb_rust_tsl_append(r_db, data, sizeof(data), (i+1)*10);
    }
    size_t r_count = fdb_rust_tsl_query_count(r_db, 15, 45);
    fdb_rust_tsdb_deinit(r_db);
    /* 对比 */
    ASSERT_EQ_INT((int)c_count, (int)r_count, "query_count mismatch");
    ASSERT_EQ_INT((int)c_count, 3, "query_count expected 3");
    rmrf(TSDB_PATH);
    TEST_PASS();
}

static void test_tsl_clean(void) {
    TEST_BEGIN("tsl_clean");
    ensure_dir(TSDB_PATH);
    /* C */
    struct fdb_tsdb c_db;
    fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    for (int i = 0; i < 3; i++) {
        uint8_t data[1] = {i};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append(&c_db, &blob);
    }
    fdb_tsl_clean(&c_db);
    size_t c_count = fdb_tsl_query_count(&c_db, 0, 0xFFFFFFFF, FDB_TSL_WRITE);
    fdb_tsdb_deinit(&c_db);
    /* Rust */
    fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
    for (int i = 0; i < 3; i++) {
        uint8_t data[1] = {i};
        fdb_rust_tsl_append(r_db, data, sizeof(data), 300 + i);
    }
    fdb_rust_tsl_clean(r_db);
    size_t r_count = fdb_rust_tsl_query_count(r_db, 0, 0xFFFFFFFF);
    fdb_rust_tsdb_deinit(r_db);
    /* 对比: clean 后都应为 0 */
    ASSERT_EQ_INT((int)c_count, 0, "C count after clean != 0");
    ASSERT_EQ_INT((int)r_count, 0, "Rust count after clean != 0");
    rmrf(TSDB_PATH);
    TEST_PASS();
}

static void test_tsl_time_range(void) {
    TEST_BEGIN("tsl_time_range");
    ensure_dir(TSDB_PATH);
    /* C: 追加 10 条 (时间戳 100,200,...,1000) */
    struct fdb_tsdb c_db;
    fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    fdb_tsl_clean(&c_db);
    for (int i = 0; i < 10; i++) {
        uint8_t data[1] = {i};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append_with_ts(&c_db, &blob, (i+1)*100);
    }
    /* 多个范围查询 */
    size_t c1 = fdb_tsl_query_count(&c_db, 0,    500, FDB_TSL_WRITE);  /* 100-500 = 5 */
    size_t c2 = fdb_tsl_query_count(&c_db, 300,  800, FDB_TSL_WRITE);  /* 300-800 = 6 */
    size_t c3 = fdb_tsl_query_count(&c_db, 999, 2000, FDB_TSL_WRITE);  /* 1000    = 1 */
    fdb_tsdb_deinit(&c_db);
    /* Rust */
    fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
    fdb_rust_tsl_clean(r_db);
    for (int i = 0; i < 10; i++) {
        uint8_t data[1] = {i};
        fdb_rust_tsl_append(r_db, data, sizeof(data), (i+1)*100);
    }
    size_t r1 = fdb_rust_tsl_query_count(r_db, 0,    500);
    size_t r2 = fdb_rust_tsl_query_count(r_db, 300,  800);
    size_t r3 = fdb_rust_tsl_query_count(r_db, 999, 2000);
    fdb_rust_tsdb_deinit(r_db);
    /* 对比 */
    ASSERT_EQ_INT((int)c1, (int)r1, "range [0,500] mismatch");
    ASSERT_EQ_INT((int)c2, (int)r2, "range [300,800] mismatch");
    ASSERT_EQ_INT((int)c3, (int)r3, "range [999,2000] mismatch");
    rmrf(TSDB_PATH);
    TEST_PASS();
}

static void test_tsl_reboot_persistence(void) {
    TEST_BEGIN("tsl_reboot_persistence");
    ensure_dir(TSDB_PATH);
    /* 写入 */
    {
        struct fdb_tsdb c_db;
        fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
        fdb_tsl_clean(&c_db);
        for (int i = 0; i < 3; i++) {
            uint8_t data[2] = {i, i+10};
            struct fdb_blob blob;
            fdb_blob_make(&blob, data, sizeof(data));
            fdb_tsl_append_with_ts(&c_db, &blob, (i+1)*10);
        }
        fdb_tsdb_deinit(&c_db);
    }
    /* C 重新读取 */
    size_t c_count;
    {
        struct fdb_tsdb c_db;
        fdb_tsdb_init(&c_db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
        c_count = fdb_tsl_query_count(&c_db, 0, 0xFFFFFFFF, FDB_TSL_WRITE);
        fdb_tsdb_deinit(&c_db);
    }
    /* Rust 写入 + 重新读取 */
    {
        fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
        fdb_rust_tsl_clean(r_db);
        for (int i = 0; i < 3; i++) {
            uint8_t data[2] = {i, i+10};
            fdb_rust_tsl_append(r_db, data, sizeof(data), (i+1)*10);
        }
        fdb_rust_tsdb_deinit(r_db);
    }
    size_t r_count;
    {
        fdb_rust_tsdb_t r_db = fdb_rust_tsdb_init(TSDB_NAME, TSDB_PATH, 128);
        r_count = fdb_rust_tsl_query_count(r_db, 0, 0xFFFFFFFF);
        fdb_rust_tsdb_deinit(r_db);
    }
    /* 对比 */
    ASSERT_EQ_INT((int)c_count, (int)r_count, "reboot persistence count mismatch");
    rmrf(TSDB_PATH);
    TEST_PASS();
}

/* ============================================================
 * 主入口
 * ============================================================ */

int main(void) {
    printf("=== FFI 功能等价测试 ===\n");
    printf("--- C 原版 vs Rust 转换版 ---\n\n");

    printf("[CRC32]\n");
    test_crc32_empty();
    test_crc32_standard();
    test_crc32_cumulative();

    printf("\n[KVDB]\n");
    test_kv_init_deinit();
    test_kv_set_get_string();
    test_kv_set_get_blob();
    test_kv_overwrite();
    test_kv_delete();
    test_kv_nonexistent();
    test_kv_multiple_keys();
    test_kv_reboot_persistence();

    printf("\n[TSDB]\n");
    test_ts_init_deinit();
    test_tsl_append();
    test_tsl_append_multiple();
    test_tsl_query_count();
    test_tsl_clean();
    test_tsl_time_range();
    test_tsl_reboot_persistence();

    printf("\n--- 结果统计 ---\n");
    printf("PASSED: %d  FAILED: %d  TOTAL: %d\n", g_passed, g_failed, g_total);

    /* 清理临时目录 */
    rmrf(KVDB_PATH);
    rmrf(TSDB_PATH);

    return (g_failed > 0) ? 1 : 0;
}
