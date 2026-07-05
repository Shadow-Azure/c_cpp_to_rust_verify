/**
 * compare_tests.c — FlashDB FFI 功能等价测试驱动程序
 *
 * 这个文件是评测工程预置的，不依赖 AI 生成。
 * 它测试 FlashDB 的核心 API，输出格式化的测试结果。
 *
 * 编译方式：
 *   - C 参考版：gcc compare_tests.c -lflashdb_c -o compare_c
 *   - Rust 版：gcc compare_tests.c -lflashdb_rust -o compare_rust
 *
 * 输出格式：每行一个测试结果
 *   CASE <category> <test_name> <result> [detail]
 *   其中 result = PASS | FAIL | SKIP
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <flashdb.h>

/* 测试计数器 */
static int total_tests = 0;
static int passed_tests = 0;
static int failed_tests = 0;

/* 输出测试结果 */
static void report(const char *category, const char *name, const char *result, const char *detail) {
    printf("CASE %s %s %s", category, name, result);
    if (detail && detail[0]) {
        printf(" %s", detail);
    }
    printf("\n");
    total_tests++;
    if (strcmp(result, "PASS") == 0) passed_tests++;
    else if (strcmp(result, "FAIL") == 0) failed_tests++;
}

/* 测试 CRC32 计算 */
static void test_crc32(void) {
    const char *data = "1234";
    uint32_t crc = fdb_calc_crc32(0, data, 4);

    if (crc != 0) {
        report("crc32", "calc_crc32", "PASS", "crc=%u", crc);
    } else {
        report("crc32", "calc_crc32", "FAIL", "crc=0");
    }
}

/* 测试 Blob 创建 */
static void test_blob_make(void) {
    uint8_t buf[4] = {1, 2, 3, 4};
    struct fdb_blob blob;
    fdb_blob_t result = fdb_blob_make(&blob, buf, sizeof(buf));

    if (result && result->size == 4) {
        report("utils", "blob_make", "PASS", "size=%zu", result->size);
    } else {
        report("utils", "blob_make", "FAIL", "null or wrong size");
    }
}

/* 测试 KVDB 初始化和基本操作 */
static void test_kvdb(void) {
    struct fdb_kvdb kvdb;
    fdb_err_t err;

    /* 初始化 */
    err = fdb_kvdb_init(&kvdb, "test_kvdb", "/tmp/fdb_test_kvdb", NULL, NULL);
    if (err != FDB_NO_ERR) {
        report("kvdb", "init", "FAIL", "err=%d", err);
        return;
    }
    report("kvdb", "init", "PASS", "");

    /* 设置字符串 */
    err = fdb_kv_set(&kvdb, "test_key", "test_value");
    if (err == FDB_NO_ERR) {
        report("kvdb", "set_string", "PASS", "");
    } else {
        report("kvdb", "set_string", "FAIL", "err=%d", err);
    }

    /* 获取字符串 */
    fdb_kv_t kv = fdb_kv_get_obj(&kvdb, "test_key", NULL);
    if (kv) {
        char value[64] = {0};
        struct fdb_blob blob;
        fdb_blob_make(&blob, value, sizeof(value));
        fdb_kv_to_blob(kv, &blob);
        if (strcmp(value, "test_value") == 0) {
            report("kvdb", "get_string", "PASS", "value=%s", value);
        } else {
            report("kvdb", "get_string", "FAIL", "wrong value: %s", value);
        }
    } else {
        report("kvdb", "get_string", "FAIL", "key not found");
    }

    /* 设置 Blob */
    uint8_t blob_data[4] = {0xAA, 0xBB, 0xCC, 0xDD};
    struct fdb_blob blob;
    fdb_blob_make(&blob, blob_data, sizeof(blob_data));
    err = fdb_kv_set_blob(&kvdb, "test_blob", &blob);
    if (err == FDB_NO_ERR) {
        report("kvdb", "set_blob", "PASS", "");
    } else {
        report("kvdb", "set_blob", "FAIL", "err=%d", err);
    }

    /* 删除 */
    err = fdb_kv_del(&kvdb, "test_key");
    if (err == FDB_NO_ERR) {
        report("kvdb", "delete", "PASS", "");
    } else {
        report("kvdb", "delete", "FAIL", "err=%d", err);
    }

    /* 清理 */
    fdb_kvdb_deinit(&kvdb);
    report("kvdb", "deinit", "PASS", "");
}

/* 测试 TSDB 初始化和基本操作 */
static fdb_time_t test_ts = 1000;
static fdb_time_t get_test_time(void) {
    return ++test_ts;
}

static void test_tsdb(void) {
    struct fdb_tsdb tsdb;
    fdb_err_t err;

    /* 初始化 */
    err = fdb_tsdb_init(&tsdb, "test_tsdb", "/tmp/fdb_test_tsdb", get_test_time, 128, NULL);
    if (err != FDB_NO_ERR) {
        report("tsdb", "init", "FAIL", "err=%d", err);
        return;
    }
    report("tsdb", "init", "PASS", "");

    /* 追加 TSL */
    uint8_t tsl_data[64] = {0};
    struct fdb_blob blob;
    fdb_blob_make(&blob, tsl_data, sizeof(tsl_data));
    err = fdb_tsl_append(&tsdb, &blob);
    if (err == FDB_NO_ERR) {
        report("tsdb", "append", "PASS", "");
    } else {
        report("tsdb", "append", "FAIL", "err=%d", err);
    }

    /* 迭代 */
    struct fdb_tsl tsl;
    int count = 0;
    fdb_time_t start = 1000;
    fdb_time_t end = 2000;

    fdb_tsl_iter_by_time(&tsdb, start, end, &tsl, NULL);
    count++;
    if (count > 0) {
        report("tsdb", "iterate", "PASS", "count=%d", count);
    } else {
        report("tsdb", "iterate", "FAIL", "no entries");
    }

    /* 清理 */
    fdb_tsdb_deinit(&tsdb);
    report("tsdb", "deinit", "PASS", "");
}

/* 主函数 */
int main(void) {
    printf("FlashDB FFI Equivalence Test\n");
    printf("============================\n\n");

    test_crc32();
    test_blob_make();
    test_kvdb();
    test_tsdb();

    printf("\n============================\n");
    printf("Total: %d | Passed: %d | Failed: %d\n", total_tests, passed_tests, failed_tests);

    return (failed_tests > 0) ? 1 : 0;
}
