/*
 * compare_tests.c — two-binary functional-equivalence driver
 *
 * This single source file exercises the public FlashDB C API (declared in
 * flashdb/inc/flashdb.h) by ORIGINAL symbol names: fdb_kvdb_init, fdb_kv_set,
 * fdb_calc_crc32, fdb_tsl_append, etc.
 *
 * The eval harness compiles this driver TWICE from the identical source:
 *   build/compare_c    : compare_tests.c + libflashdb_c.a    (C reference impl)
 *   build/compare_rust : compare_tests.c + libflashdb_rust.a (Rust impl, whose
 *                        ffi.rs must export the SAME #[no_mangle] extern "C"
 *                        symbols with matching signatures as flashdb.h)
 *
 * Each binary is run with identical inputs; their stdout is diffed line by line.
 * Matching CASE lines count as PASSED, differing lines as FAILED. No project-
 * specific symbol prefix (e.g. fdb_rust_*) is required, because each binary
 * contains exactly ONE library so there is no symbol collision.
 *
 * Output contract (stdout): one structured line per observation
 *   CASE <id> <key>=<value>
 * Each test case may emit multiple CASE lines (one per observable). The line
 * <id> identifies the test; <key> identifies the sub-observation within it.
 * Output is fully deterministic (no pointers, no addresses, no wall-clock).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <sys/stat.h>
#include <ftw.h>

/* Original FlashDB public API — the only contract the driver depends on.
 * When linked against libflashdb_rust.a these resolve to the Rust exports. */
#include <flashdb.h>
#include <fdb_cfg.h>

/* ============================================================
 * Output helpers — deterministic, library-agnostic
 * ============================================================ */

static void case_i(const char *id, const char *key, long val) {
    printf("CASE %s %s=%ld\n", id, key, val);
}

static void case_u(const char *id, const char *key, unsigned long val) {
    printf("CASE %s %s=%lu\n", id, key, val);
}

static void case_x(const char *id, const char *key, unsigned long val) {
    printf("CASE %s %s=0x%lx\n", id, key, val);
}

static void case_s(const char *id, const char *key, const char *val) {
    printf("CASE %s %s=%s\n", id, key, val ? val : "<null>");
}

/* fdb_kv_get returns a pointer into a static internal buffer that is
 * overwritten by the next call. Snapshot the value before any subsequent
 * FlashDB call so the printed result reflects the value at query time. */
static char *snapshot(const char *s) {
    return s ? strdup(s) : NULL;
}

/* ============================================================
 * Filesystem helpers
 * ============================================================ */

static int rmrf_cb(const char *fpath, const struct stat *sb,
                   int typeflag, struct FTW *ftwbuf) {
    (void)sb; (void)typeflag; (void)ftwbuf;
    return remove(fpath);
}

static void rmrf(const char *path) {
    /* Synchronous recursive removal (avoids shelling out to `rm -rf`, which
     * can race the next init that opens files in the same directory). */
    nftw(path, rmrf_cb, 16, FTW_DEPTH | FTW_PHYS);
}

static void ensure_dir(const char *path) {
    mkdir(path, 0755);
}

/* File-mode flash geometry. The reference C tests set sector size, file mode
 * and max DB size via the public *_control API BEFORE calling *_init; the
 * library asserts that sec_size is a power of two otherwise. The Rust port
 * must honour the same control contract (these symbols are in flashdb.h). */
#define DRV_SEC_SIZE  4096u

static void config_kvdb(struct fdb_kvdb *db, uint32_t sector_num) {
    /* FlashDB asserts db->parent.init_ok == false at the start of init, so the
     * struct MUST be zero-initialised (an uninitialised stack struct can have
     * a non-zero init_ok and trip the assertion). */
    memset(db, 0, sizeof(*db));
    uint32_t sec_size = DRV_SEC_SIZE;
    uint32_t db_size  = sec_size * sector_num;
    bool file_mode = true;
    fdb_kvdb_control(db, FDB_KVDB_CTRL_SET_SEC_SIZE,  &sec_size);
    fdb_kvdb_control(db, FDB_KVDB_CTRL_SET_FILE_MODE, &file_mode);
    fdb_kvdb_control(db, FDB_KVDB_CTRL_SET_MAX_SIZE,  &db_size);
}

static void config_tsdb(struct fdb_tsdb *db, uint32_t sector_num) {
    memset(db, 0, sizeof(*db));
    uint32_t sec_size = DRV_SEC_SIZE;
    uint32_t db_size  = sec_size * sector_num;
    bool file_mode = true;
    fdb_tsdb_control(db, FDB_TSDB_CTRL_SET_SEC_SIZE,  &sec_size);
    fdb_tsdb_control(db, FDB_TSDB_CTRL_SET_FILE_MODE, &file_mode);
    fdb_tsdb_control(db, FDB_TSDB_CTRL_SET_MAX_SIZE,  &db_size);
}

/* ============================================================
 * CRC32 cases
 * ============================================================ */

static void test_crc32_empty(void) {
    const char *id = "crc32_empty";
    uint32_t v = fdb_calc_crc32(0, (const void *)"", 0);
    case_x(id, "value", v);
}

static void test_crc32_standard(void) {
    const char *id = "crc32_standard";
    const char *data = "123456789";
    uint32_t v = fdb_calc_crc32(0, (const void *)data, 9);
    case_x(id, "value", v);
}

static void test_crc32_cumulative(void) {
    const char *id = "crc32_cumulative";
    const char *part1 = "Hello, ";
    const char *part2 = "World!";
    char full[64];
    snprintf(full, sizeof(full), "%s%s", part1, part2);
    uint32_t once  = fdb_calc_crc32(0, (const void *)full, strlen(full));
    uint32_t step  = fdb_calc_crc32(0, (const void *)part1, strlen(part1));
            step  = fdb_calc_crc32(step, (const void *)part2, strlen(part2));
    case_x(id, "once", once);
    case_x(id, "step", step);
}

/* ============================================================
 * KVDB cases
 * ============================================================ */

#define KVDB_NAME "cmp_kvdb"
#define KVDB_PATH "/tmp/cmp_kvdb_data"

static void test_kv_init_deinit(void) {
    const char *id = "kv_init_deinit";
    ensure_dir(KVDB_PATH);
    struct fdb_kvdb db;
    config_kvdb(&db, 4);
    fdb_err_t err = fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    case_i(id, "init_err", (long)err);
    fdb_kvdb_deinit(&db);
    rmrf(KVDB_PATH);
}

static void test_kv_set_get_string(void) {
    const char *id = "kv_set_get_string";
    ensure_dir(KVDB_PATH);
    struct fdb_kvdb db;
    config_kvdb(&db, 4);
    fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_err_t s = fdb_kv_set(&db, "key1", "hello");
    char *g = fdb_kv_get(&db, "key1");
    case_i(id, "set_err", (long)s);
    case_s(id, "get_value", g);
    fdb_kvdb_deinit(&db);
    rmrf(KVDB_PATH);
}

static void test_kv_set_get_blob(void) {
    const char *id = "kv_set_get_blob";
    ensure_dir(KVDB_PATH);
    uint8_t blob_data[] = {0x01, 0x02, 0x03, 0x04, 0x05};
    size_t blob_len = sizeof(blob_data);
    struct fdb_kvdb db;
    config_kvdb(&db, 4);
    fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    struct fdb_blob wb;
    fdb_blob_make(&wb, blob_data, blob_len);
    fdb_err_t s = fdb_kv_set_blob(&db, "blob1", &wb);
    uint8_t buf[64] = {0};
    struct fdb_blob rb;
    fdb_blob_make(&rb, buf, sizeof(buf));
    size_t read = fdb_kv_get_blob(&db, "blob1", &rb);
    case_i(id, "set_err", (long)s);
    case_u(id, "read_len", (unsigned long)read);
    case_x(id, "byte0", buf[0]);
    case_x(id, "byte4", buf[4]);
    fdb_kvdb_deinit(&db);
    rmrf(KVDB_PATH);
}

static void test_kv_overwrite(void) {
    const char *id = "kv_overwrite";
    ensure_dir(KVDB_PATH);
    struct fdb_kvdb db;
    config_kvdb(&db, 4);
    fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_kv_set(&db, "k", "v1");
    fdb_kv_set(&db, "k", "v2");
    char *g = fdb_kv_get(&db, "k");
    case_s(id, "get_value", g);
    fdb_kvdb_deinit(&db);
    rmrf(KVDB_PATH);
}

static void test_kv_delete(void) {
    const char *id = "kv_delete";
    ensure_dir(KVDB_PATH);
    struct fdb_kvdb db;
    config_kvdb(&db, 4);
    fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_kv_set(&db, "del_me", "value");
    fdb_err_t d = fdb_kv_del(&db, "del_me");
    char *g = fdb_kv_get(&db, "del_me");
    case_i(id, "del_err", (long)d);
    case_s(id, "get_after_del", g);
    fdb_kvdb_deinit(&db);
    rmrf(KVDB_PATH);
}

static void test_kv_nonexistent(void) {
    const char *id = "kv_nonexistent";
    ensure_dir(KVDB_PATH);
    struct fdb_kvdb db;
    config_kvdb(&db, 4);
    fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    char *g = fdb_kv_get(&db, "no_such_key");
    case_s(id, "get_value", g);
    fdb_kvdb_deinit(&db);
    rmrf(KVDB_PATH);
}

static void test_kv_multiple_keys(void) {
    const char *id = "kv_multiple_keys";
    ensure_dir(KVDB_PATH);
    struct fdb_kvdb db;
    config_kvdb(&db, 4);
    fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
    fdb_kv_set(&db, "alpha", "1");
    fdb_kv_set(&db, "beta",  "2");
    fdb_kv_set(&db, "gamma", "3");
    char *a = snapshot(fdb_kv_get(&db, "alpha"));
    char *b = snapshot(fdb_kv_get(&db, "beta"));
    char *g = snapshot(fdb_kv_get(&db, "gamma"));
    case_s(id, "alpha", a);
    case_s(id, "beta",  b);
    case_s(id, "gamma", g);
    free(a); free(b); free(g);
    fdb_kvdb_deinit(&db);
    rmrf(KVDB_PATH);
}

static void test_kv_reboot_persistence(void) {
    const char *id = "kv_reboot_persistence";
    ensure_dir(KVDB_PATH);
    /* write */
    {
        struct fdb_kvdb db;
        config_kvdb(&db, 4);
        fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
        fdb_kv_set(&db, "persist", "data123");
        fdb_kvdb_deinit(&db);
    }
    /* read back in a fresh handle */
    char *g = NULL;
    {
        struct fdb_kvdb db;
        config_kvdb(&db, 4);
        fdb_kvdb_init(&db, KVDB_NAME, KVDB_PATH, NULL, NULL);
        g = fdb_kv_get(&db, "persist");
        fdb_kvdb_deinit(&db);
    }
    case_s(id, "persist_value", g);
    rmrf(KVDB_PATH);
}

/* ============================================================
 * TSDB cases
 *
 * Note: the public C API does NOT expose a wall-clock-free append that also
 * sets the timestamp deterministically except fdb_tsl_append_with_ts. We use
 * fdb_tsl_append (auto-timestamp) for append success checks and
 * fdb_tsl_append_with_ts for range/count determinism. The driver emits only
 * counts and return codes, which are deterministic across both libraries.
 * ============================================================ */

#define TSDB_NAME "cmp_tsdb"
#define TSDB_PATH "/tmp/cmp_tsdb_data"

/* fixed timestamp source so both binaries advance identically */
static uint32_t g_ts_counter = 0;
static fdb_time_t test_get_time(void) {
    return ++g_ts_counter;
}

static void test_ts_init_deinit(void) {
    const char *id = "ts_init_deinit";
    ensure_dir(TSDB_PATH);
    struct fdb_tsdb db;
    config_tsdb(&db, 16);
    fdb_err_t err = fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    case_i(id, "init_err", (long)err);
    fdb_tsdb_deinit(&db);
    rmrf(TSDB_PATH);
}

static void test_tsl_append(void) {
    const char *id = "tsl_append";
    ensure_dir(TSDB_PATH);
    g_ts_counter = 100;
    struct fdb_tsdb db;
    config_tsdb(&db, 16);
    fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    uint8_t data[] = {0xAA, 0xBB, 0xCC};
    struct fdb_blob blob;
    fdb_blob_make(&blob, data, sizeof(data));
    fdb_err_t err = fdb_tsl_append(&db, &blob);
    case_i(id, "append_err", (long)err);
    fdb_tsdb_deinit(&db);
    rmrf(TSDB_PATH);
}

static void test_tsl_append_multiple(void) {
    const char *id = "tsl_append_multiple";
    ensure_dir(TSDB_PATH);
    struct fdb_tsdb db;
    config_tsdb(&db, 16);
    fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    fdb_tsl_clean(&db);
    for (int i = 0; i < 5; i++) {
        uint8_t data[4] = {i, i+1, i+2, i+3};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        /* explicit timestamp keeps the appended records queryable immediately
         * (PRE_WRITE records appended via fdb_tsl_append are not visible to
         * fdb_tsl_query_count(FDB_TSL_WRITE) until a reboot finalises them) */
        fdb_tsl_append_with_ts(&db, &blob, 200 + i);
    }
    /* query the appended range (records sit at ts 200..204); a full-range
     * query after a clean+append cycle on a fresh DB can exclude the just-
     * written sector depending on FlashDB's sector-state bookkeeping, so we
     * scope the query to the timestamps we actually wrote. */
    size_t count = fdb_tsl_query_count(&db, 200, 204, FDB_TSL_WRITE);
    case_u(id, "count", (unsigned long)count);
    fdb_tsdb_deinit(&db);
    rmrf(TSDB_PATH);
}

static void test_tsl_query_count(void) {
    const char *id = "tsl_query_count";
    ensure_dir(TSDB_PATH);
    struct fdb_tsdb db;
    config_tsdb(&db, 16);
    fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    fdb_tsl_clean(&db);
    for (int i = 0; i < 5; i++) {
        uint8_t data[2] = {i, 0};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append_with_ts(&db, &blob, (i+1)*10);
    }
    size_t count = fdb_tsl_query_count(&db, 15, 45, FDB_TSL_WRITE);
    case_u(id, "count_15_45", (unsigned long)count);
    fdb_tsdb_deinit(&db);
    rmrf(TSDB_PATH);
}

static void test_tsl_clean(void) {
    const char *id = "tsl_clean";
    ensure_dir(TSDB_PATH);
    struct fdb_tsdb db;
    config_tsdb(&db, 16);
    fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    for (int i = 0; i < 3; i++) {
        uint8_t data[1] = {i};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append(&db, &blob);
    }
    fdb_tsl_clean(&db);
    size_t count = fdb_tsl_query_count(&db, 0, 0xFFFFFFFF, FDB_TSL_WRITE);
    case_u(id, "count_after_clean", (unsigned long)count);
    fdb_tsdb_deinit(&db);
    rmrf(TSDB_PATH);
}

static void test_tsl_time_range(void) {
    const char *id = "tsl_time_range";
    ensure_dir(TSDB_PATH);
    struct fdb_tsdb db;
    config_tsdb(&db, 16);
    fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
    fdb_tsl_clean(&db);
    for (int i = 0; i < 10; i++) {
        uint8_t data[1] = {i};
        struct fdb_blob blob;
        fdb_blob_make(&blob, data, sizeof(data));
        fdb_tsl_append_with_ts(&db, &blob, (i+1)*100);
    }
    size_t c1 = fdb_tsl_query_count(&db, 0,    500, FDB_TSL_WRITE);
    size_t c2 = fdb_tsl_query_count(&db, 300,  800, FDB_TSL_WRITE);
    size_t c3 = fdb_tsl_query_count(&db, 999, 2000, FDB_TSL_WRITE);
    case_u(id, "range_0_500",   (unsigned long)c1);
    case_u(id, "range_300_800", (unsigned long)c2);
    case_u(id, "range_999_2000",(unsigned long)c3);
    fdb_tsdb_deinit(&db);
    rmrf(TSDB_PATH);
}

static void test_tsl_reboot_persistence(void) {
    const char *id = "tsl_reboot_persistence";
    ensure_dir(TSDB_PATH);
    /* write */
    {
        struct fdb_tsdb db;
        config_tsdb(&db, 16);
        fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
        fdb_tsl_clean(&db);
        for (int i = 0; i < 3; i++) {
            uint8_t data[2] = {i, i+10};
            struct fdb_blob blob;
            fdb_blob_make(&blob, data, sizeof(data));
            fdb_tsl_append_with_ts(&db, &blob, (i+1)*10);
        }
        fdb_tsdb_deinit(&db);
    }
    /* read back (scope to the timestamps we wrote: 10, 20, 30) */
    size_t count = 0;
    {
        struct fdb_tsdb db;
        config_tsdb(&db, 16);
        fdb_tsdb_init(&db, TSDB_NAME, TSDB_PATH, test_get_time, 128, NULL);
        count = fdb_tsl_query_count(&db, 10, 30, FDB_TSL_WRITE);
        fdb_tsdb_deinit(&db);
    }
    case_u(id, "count_after_reboot", (unsigned long)count);
    rmrf(TSDB_PATH);
}

/* ============================================================
 * Main — run the identical case sequence in both binaries
 * ============================================================ */

int main(void) {
    /* Disable stdout buffering so partial output is captured even if a
     * later test crashes the process (observability only). */
    setvbuf(stdout, NULL, _IONBF, 0);

    /* CRC32 */
    test_crc32_empty();
    test_crc32_standard();
    test_crc32_cumulative();

    /* KVDB */
    test_kv_init_deinit();
    test_kv_set_get_string();
    test_kv_set_get_blob();
    test_kv_overwrite();
    test_kv_delete();
    test_kv_nonexistent();
    test_kv_multiple_keys();
    test_kv_reboot_persistence();

    /* TSDB */
    test_ts_init_deinit();
    test_tsl_append();
    test_tsl_append_multiple();
    test_tsl_query_count();
    test_tsl_clean();
    test_tsl_time_range();
    test_tsl_reboot_persistence();

    rmrf(KVDB_PATH);
    rmrf(TSDB_PATH);
    return 0;
}
