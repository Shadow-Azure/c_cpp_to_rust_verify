/**
 * compare_tests.c — libuv FFI 功能等价测试驱动程序
 *
 * 测试 libuv 的确定性 API，输出格式化的 CASE 行。
 * 同一驱动编译两次：一次链接 C 库，一次链接 Rust FFI 库。
 * 两个二进制的 stdout 按 CASE 行排序后 comm 对比。
 *
 * 输出格式：
 *   CASE <category> <test_name> PASS <detail>
 */

#include <uv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <signal.h>

static int total_tests = 0;
static int passed_tests = 0;
static int failed_tests = 0;

static void report(const char *category, const char *name,
                   const char *result, const char *detail) {
    printf("CASE %s %s %s", category, name, result);
    if (detail && detail[0]) {
        printf(" %s", detail);
    }
    printf("\n");
    total_tests++;
    if (strcmp(result, "PASS") == 0) passed_tests++;
    else if (strcmp(result, "FAIL") == 0) failed_tests++;
}

/* ============================================================
 * Category 1: version_info (完全确定性)
 * ============================================================ */
static void test_version_info(void) {
    unsigned int version = uv_version();
    char detail[32];
    snprintf(detail, sizeof(detail), "%u", version);
    report("version_info", "uv_version",
           version > 0 ? "PASS" : "FAIL", detail);

    const char *ver_str = uv_version_string();
    report("version_info", "uv_version_string",
           (ver_str && ver_str[0]) ? "PASS" : "FAIL",
           ver_str ? ver_str : "NULL");
}

/* ============================================================
 * Category 2: sizes (固定常量 — 验证 Rust 结构体布局与 C 一致)
 * ============================================================ */
static void test_sizes(void) {
    char detail[32];

    /* Loop size */
    size_t loop_sz = uv_loop_size();
    snprintf(detail, sizeof(detail), "%zu", loop_sz);
    report("sizes", "loop_size", loop_sz > 0 ? "PASS" : "FAIL", detail);

    /* Handle sizes */
    struct { uv_handle_type type; const char *name; } handles[] = {
        {UV_TIMER,      "handle_timer"},
        {UV_TCP,        "handle_tcp"},
        {UV_UDP,        "handle_udp"},
        {UV_NAMED_PIPE, "handle_named_pipe"},
        {UV_TTY,        "handle_tty"},
        {UV_PREPARE,    "handle_prepare"},
        {UV_CHECK,      "handle_check"},
        {UV_IDLE,       "handle_idle"},
        {UV_ASYNC,      "handle_async"},
        {UV_POLL,       "handle_poll"},
        {UV_SIGNAL,     "handle_signal"},
        {UV_PROCESS,    "handle_process"},
    };
    int nhandles = sizeof(handles) / sizeof(handles[0]);
    for (int i = 0; i < nhandles; i++) {
        size_t sz = uv_handle_size(handles[i].type);
        snprintf(detail, sizeof(detail), "%zu", sz);
        report("sizes", handles[i].name,
               sz > 0 ? "PASS" : "FAIL", detail);
    }

    /* Request sizes */
    struct { uv_req_type type; const char *name; } reqs[] = {
        {UV_REQ,         "req_base"},
        {UV_CONNECT,     "req_connect"},
        {UV_WRITE,       "req_write"},
        {UV_SHUTDOWN,    "req_shutdown"},
        {UV_UDP_SEND,    "req_udp_send"},
        {UV_FS,          "req_fs"},
        {UV_WORK,        "req_work"},
        {UV_GETADDRINFO, "req_getaddrinfo"},
        {UV_GETNAMEINFO, "req_getnameinfo"},
    };
    int nreqs = sizeof(reqs) / sizeof(reqs[0]);
    for (int i = 0; i < nreqs; i++) {
        size_t sz = uv_req_size(reqs[i].type);
        snprintf(detail, sizeof(detail), "%zu", sz);
        report("sizes", reqs[i].name,
               sz > 0 ? "PASS" : "FAIL", detail);
    }
}

/* ============================================================
 * Category 3: error_strings (完全确定性)
 * ============================================================ */
static void test_error_strings(void) {
    /* uv_strerror */
    report("error_strings", "strerror_0",
           "PASS", uv_strerror(0));
    report("error_strings", "strerror_einval",
           "PASS", uv_strerror(UV_EINVAL));
    report("error_strings", "strerror_enoent",
           "PASS", uv_strerror(UV_ENOENT));
    report("error_strings", "strerror_eacces",
           "PASS", uv_strerror(UV_EACCES));
    report("error_strings", "strerror_econn",
           "PASS", uv_strerror(UV_ECONNREFUSED));

    /* uv_err_name */
    report("error_strings", "errname_0",
           "PASS", uv_err_name(0));
    report("error_strings", "errname_einval",
           "PASS", uv_err_name(UV_EINVAL));
    report("error_strings", "errname_enoent",
           "PASS", uv_err_name(UV_ENOENT));
    report("error_strings", "errname_eacces",
           "PASS", uv_err_name(UV_EACCES));

    /* uv_translate_sys_error */
    char detail[32];
    int translated = uv_translate_sys_error(EINVAL);
    snprintf(detail, sizeof(detail), "%d", translated);
    report("error_strings", "translate_einval",
           translated == UV_EINVAL ? "PASS" : "FAIL", detail);
}

/* ============================================================
 * Category 4: loop_lifecycle (同步确定性)
 * ============================================================ */
static void test_loop_lifecycle(void) {
    char detail[32];
    uv_loop_t loop;

    int r = uv_loop_init(&loop);
    snprintf(detail, sizeof(detail), "%d", r);
    report("loop_lifecycle", "loop_init",
           r == 0 ? "PASS" : "FAIL", detail);

    int alive = uv_loop_alive(&loop);
    snprintf(detail, sizeof(detail), "%d", alive);
    report("loop_lifecycle", "loop_alive_before_run",
           alive == 0 ? "PASS" : "FAIL", detail);

    r = uv_run(&loop, UV_RUN_DEFAULT);
    snprintf(detail, sizeof(detail), "%d", r);
    report("loop_lifecycle", "loop_run_default",
           r == 0 ? "PASS" : "FAIL", detail);

    r = uv_loop_close(&loop);
    snprintf(detail, sizeof(detail), "%d", r);
    report("loop_lifecycle", "loop_close",
           r == 0 ? "PASS" : "FAIL", detail);

    uv_loop_t *default_loop = uv_default_loop();
    report("loop_lifecycle", "default_loop",
           default_loop != NULL ? "PASS" : "FAIL",
           default_loop != NULL ? "non-null" : "null");

    /* loop_configure: block SIGPIPE (common on Unix) */
    r = uv_loop_init(&loop);
    if (r == 0) {
#ifdef UV_LOOP_BLOCK_SIGNAL
        r = uv_loop_configure(&loop, UV_LOOP_BLOCK_SIGNAL, SIGPIPE);
        snprintf(detail, sizeof(detail), "%d", r);
        report("loop_lifecycle", "loop_block_sigpipe",
               r == 0 ? "PASS" : "FAIL", detail);
#else
        report("loop_lifecycle", "loop_block_sigpipe", "SKIP", "not available");
#endif
        uv_loop_close(&loop);
    }
}

/* ============================================================
 * Category 5: timer_ops (基本确定性)
 * ============================================================ */
static void dummy_timer_cb(uv_timer_t *handle) {
    (void)handle;
}

static void test_timer_ops(uv_loop_t *loop) {
    char detail[32];
    uv_timer_t timer;

    int r = uv_timer_init(loop, &timer);
    snprintf(detail, sizeof(detail), "%d", r);
    report("timer_ops", "timer_init",
           r == 0 ? "PASS" : "FAIL", detail);

    r = uv_timer_start(&timer, dummy_timer_cb, 60000, 0);
    snprintf(detail, sizeof(detail), "%d", r);
    report("timer_ops", "timer_start",
           r == 0 ? "PASS" : "FAIL", detail);

    int active = uv_is_active((uv_handle_t *)&timer);
    snprintf(detail, sizeof(detail), "%d", active);
    report("timer_ops", "timer_is_active",
           active == 1 ? "PASS" : "FAIL", detail);

    uv_timer_set_repeat(&timer, 1000);
    uint64_t repeat = uv_timer_get_repeat(&timer);
    snprintf(detail, sizeof(detail), "%lu", (unsigned long)repeat);
    report("timer_ops", "timer_get_repeat",
           repeat == 1000 ? "PASS" : "FAIL", detail);

    r = uv_timer_stop(&timer);
    snprintf(detail, sizeof(detail), "%d", r);
    report("timer_ops", "timer_stop",
           r == 0 ? "PASS" : "FAIL", detail);

    active = uv_is_active((uv_handle_t *)&timer);
    snprintf(detail, sizeof(detail), "%d", active);
    report("timer_ops", "timer_inactive_after_stop",
           active == 0 ? "PASS" : "FAIL", detail);

    uv_close((uv_handle_t *)&timer, NULL);
}

/* ============================================================
 * Category 6: system_info (归一化 — 值可能变化)
 * ============================================================ */
static void test_system_info(void) {
    uint64_t total_mem = uv_get_total_memory();
    report("system_info", "total_memory",
           total_mem > 0 ? "PASS" : "FAIL",
           total_mem > 0 ? "positive" : "zero");

    uint64_t constrained_mem = uv_get_constrained_memory();
    report("system_info", "constrained_memory", "PASS",
           constrained_mem > 0 ? "positive" : "zero_or_unconstrained");

    uint64_t free_mem = uv_get_free_memory();
    report("system_info", "free_memory",
           free_mem > 0 ? "PASS" : "FAIL",
           free_mem > 0 ? "positive" : "zero");

    int pid = (int)uv_os_getpid();
    report("system_info", "getpid",
           pid > 0 ? "PASS" : "FAIL",
           pid > 0 ? "positive" : "zero");

    uint64_t hrtime = uv_hrtime();
    report("system_info", "hrtime",
           hrtime > 0 ? "PASS" : "FAIL",
           hrtime > 0 ? "nonzero" : "zero");
}

/* ============================================================
 * main
 * ============================================================ */
int main(void) {
    uv_loop_t *loop = uv_default_loop();
    if (!loop) {
        fprintf(stderr, "FATAL: uv_default_loop() returned NULL\n");
        return 1;
    }

    test_version_info();
    test_sizes();
    test_error_strings();
    test_loop_lifecycle();
    test_timer_ops(loop);
    test_system_info();

    /* Process pending close callbacks */
    uv_run(loop, UV_RUN_DEFAULT);
    uv_loop_close(loop);

    fprintf(stderr, "\n=== Summary: %d passed, %d failed, %d total ===\n",
            passed_tests, failed_tests, total_tests);

    return failed_tests > 0 ? 1 : 0;
}
