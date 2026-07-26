/**
 * libuv_bench.c — C 基准测试，测量 libuv 核心操作性能。
 * 输出格式与 FlashDB 一致：
 *   "  <name> | <n> ops | <us> us | <ops/s> ops/s | <us/op> us/op"
 */

#include <uv.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define N_OPS 10000

static double now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e6 + ts.tv_nsec / 1e3;
}

static void print_result(const char *name, int n_ops, double elapsed_us) {
    double ops_per_s = n_ops / (elapsed_us / 1e6);
    double us_per_op = elapsed_us / n_ops;
    printf("  %s | %d ops | %.1f us | %.1f ops/s | %.2f us/op\n",
           name, n_ops, elapsed_us, ops_per_s, us_per_op);
}

/* --- timer_throughput: create N timers with 0ms timeout, run loop --- */
static void timer_cb(uv_timer_t *handle) {
    uv_close((uv_handle_t *)handle, NULL);
}

static void bench_timer_throughput(uv_loop_t *loop) {
    uv_timer_t *timers = malloc(N_OPS * sizeof(uv_timer_t));
    double start = now_us();

    for (int i = 0; i < N_OPS; i++) {
        uv_timer_init(loop, &timers[i]);
        uv_timer_start(&timers[i], timer_cb, 0, 0);
    }
    uv_run(loop, UV_RUN_DEFAULT);

    double elapsed = now_us() - start;
    print_result("timer_throughput", N_OPS, elapsed);
    free(timers);
}

/* --- loop_overhead: run empty loop N times --- */
static void bench_loop_overhead(uv_loop_t *loop) {
    double start = now_us();

    for (int i = 0; i < N_OPS; i++) {
        uv_run(loop, UV_RUN_NOWAIT);
    }

    double elapsed = now_us() - start;
    print_result("loop_overhead", N_OPS, elapsed);
}

/* --- handle_init: init + close N handles --- */
static void close_cb(uv_handle_t *handle) {
    (void)handle;
}

static void bench_handle_init(uv_loop_t *loop) {
    uv_timer_t *handles = malloc(N_OPS * sizeof(uv_timer_t));
    double start = now_us();

    for (int i = 0; i < N_OPS; i++) {
        uv_timer_init(loop, &handles[i]);
        uv_close((uv_handle_t *)&handles[i], close_cb);
    }
    uv_run(loop, UV_RUN_DEFAULT);

    double elapsed = now_us() - start;
    print_result("handle_init", N_OPS, elapsed);
    free(handles);
}

int main(void) {
    uv_loop_t *loop = uv_default_loop();
    if (!loop) {
        fprintf(stderr, "FATAL: uv_default_loop() failed\n");
        return 1;
    }

    bench_timer_throughput(loop);
    bench_loop_overhead(loop);
    bench_handle_init(loop);

    uv_loop_close(loop);
    return 0;
}
