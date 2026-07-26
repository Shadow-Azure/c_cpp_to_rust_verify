/**
 * cjson_bench.c — C 基准测试，测量 cJSON 核心操作性能。
 * 输出格式与 libuv 一致：
 *   "  <name> | <n> ops | <us> us | <ops/s> ops/s | <us/op> us/op"
 */

#include <cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define N_SMALL 10000
#define N_LARGE 1000

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

/* Sample small flat JSON object */
static const char *SMALL_JSON =
    "{\"name\":\"cJSON\",\"ver\":1.7,\"ok\":true,\"count\":42,\"ratio\":3.14,"
    "\"flag\":\"yes\",\"tag\":\"bench\",\"id\":7,\"active\":false,\"score\":100}";

/* Build a large JSON document: array of 1000 objects each with 3 numeric fields.
 * Returns a malloc'd string the caller must free. */
static char *build_large_json(int n) {
    cJSON *arr = cJSON_CreateArray();
    for (int i = 0; i < n; i++) {
        cJSON *o = cJSON_CreateObject();
        cJSON_AddNumberToObject(o, "x", (double)i);
        cJSON_AddNumberToObject(o, "y", (double)(i * 2));
        cJSON_AddNumberToObject(o, "z", (double)(i * 3));
        cJSON_AddItemToArray(arr, o);
    }
    char *out = cJSON_PrintUnformatted(arr);
    cJSON_Delete(arr);
    return out;
}

/* --- parse_small: parse flat object N times --- */
static void bench_parse_small(const char *src) {
    double start = now_us();
    for (int i = 0; i < N_SMALL; i++) {
        cJSON *j = cJSON_Parse(src);
        cJSON_Delete(j);
    }
    print_result("parse_small", N_SMALL, now_us() - start);
}

/* --- parse_large: parse 1000-element array N times --- */
static void bench_parse_large(const char *src) {
    double start = now_us();
    for (int i = 0; i < N_LARGE; i++) {
        cJSON *j = cJSON_Parse(src);
        cJSON_Delete(j);
    }
    print_result("parse_large", N_LARGE, now_us() - start);
}

/* --- print_unformatted: parse once, compact-print N times --- */
static void bench_print_unformatted(const char *src) {
    cJSON *j = cJSON_Parse(src);
    double start = now_us();
    for (int i = 0; i < N_LARGE; i++) {
        char *out = cJSON_PrintUnformatted(j);
        cJSON_free(out);
    }
    print_result("print_unformatted", N_LARGE, now_us() - start);
    cJSON_Delete(j);
}

/* --- traverse: parse once, walk array summing x field, N times --- */
static void bench_traverse(const char *src) {
    cJSON *j = cJSON_Parse(src);
    double start = now_us();
    volatile double sink = 0.0;
    for (int i = 0; i < N_LARGE; i++) {
        cJSON *arr = j;
        cJSON *child;
        cJSON_ArrayForEach(child, arr) {
            cJSON *x = cJSON_GetObjectItem(child, "x");
            if (cJSON_IsNumber(x)) sink += cJSON_GetNumberValue(x);
        }
    }
    (void)sink;
    print_result("traverse", N_LARGE, now_us() - start);
    cJSON_Delete(j);
}

int main(void) {
    /* Warm up cJSON once to avoid first-call allocation noise dominating. */
    {
        cJSON *j = cJSON_Parse(SMALL_JSON);
        cJSON_Delete(j);
    }

    char *large = build_large_json(1000);
    if (!large) {
        fprintf(stderr, "FATAL: failed to build large JSON\n");
        return 1;
    }

    bench_parse_small(SMALL_JSON);
    bench_parse_large(large);
    bench_print_unformatted(large);
    bench_traverse(large);

    cJSON_free(large);
    return 0;
}
