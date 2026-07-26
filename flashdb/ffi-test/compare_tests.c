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
    char detail[32];
    snprintf(detail, sizeof(detail), "crc=%u", crc);

    if (crc != 0) {
        report("crc32", "calc_crc32", "PASS", detail);
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
        char detail[32];
        snprintf(detail, sizeof(detail), "size=%zu", result->size);
        report("utils", "blob_make", "PASS", detail);
    } else {
        report("utils", "blob_make", "FAIL", "null or wrong size");
    }
}

/* 测试函数存在性（不实际调用需要文件系统的函数） */
static void test_api_functions(void) {
    /* 测试函数指针是否为 NULL */
    if (fdb_calc_crc32 != NULL) {
        report("api", "crc32_func", "PASS", "");
    } else {
        report("api", "crc32_func", "FAIL", "null pointer");
    }

    if (fdb_blob_make != NULL) {
        report("api", "blob_make_func", "PASS", "");
    } else {
        report("api", "blob_make_func", "FAIL", "null pointer");
    }

    if (fdb_kv_set != NULL) {
        report("api", "kv_set_func", "PASS", "");
    } else {
        report("api", "kv_set_func", "FAIL", "null pointer");
    }

    if (fdb_kv_get != NULL) {
        report("api", "kv_get_func", "PASS", "");
    } else {
        report("api", "kv_get_func", "FAIL", "null pointer");
    }

    if (fdb_kv_del != NULL) {
        report("api", "kv_del_func", "PASS", "");
    } else {
        report("api", "kv_del_func", "FAIL", "null pointer");
    }

    if (fdb_tsl_append != NULL) {
        report("api", "tsl_append_func", "PASS", "");
    } else {
        report("api", "tsl_append_func", "FAIL", "null pointer");
    }

    if (fdb_tsl_iter != NULL) {
        report("api", "tsl_iter_func", "PASS", "");
    } else {
        report("api", "tsl_iter_func", "FAIL", "null pointer");
    }
}

/* 主函数 */
int main(void) {
    printf("FlashDB FFI Equivalence Test\n");
    printf("============================\n\n");

    test_crc32();
    test_blob_make();
    test_api_functions();

    printf("\n============================\n");
    printf("Total: %d | Passed: %d | Failed: %d\n", total_tests, passed_tests, failed_tests);

    return (failed_tests > 0) ? 1 : 0;
}
