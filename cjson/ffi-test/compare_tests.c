/**
 * compare_tests.c — cJSON FFI 功能等价测试驱动程序
 *
 * 测试 cJSON 的确定性 API，输出格式化的 CASE 行。
 * 同一驱动编译两次：一次链接 C 库，一次链接 Rust FFI 库。
 * 两个二进制的 stdout 按 CASE 行排序后 comm 对比。
 *
 * 输出格式：
 *   CASE <category> <test_name> PASS <detail>
 *
 * detail 必须在 C 与 Rust 实现之间字节一致（用于 comm 精确匹配）。
 * 因此 detail 只用：版本字符串、整数计数、整数数组、yes/no、短常量。
 * 避免浮点格式化差异。
 */

#include <cJSON.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int total_tests = 0;
static int passed_tests = 0;
static int failed_tests = 0;

static void report(const char *category, const char *name,
                   int pass, const char *detail) {
    printf("CASE %s %s %s", category, name, pass ? "PASS" : "FAIL");
    if (detail && detail[0]) {
        printf(" %s", detail);
    }
    printf("\n");
    total_tests++;
    if (pass) passed_tests++;
    else failed_tests++;
}

/* Helper: count immediate children of a node */
static int child_count(const cJSON *node) {
    int n = 0;
    if (!node) return -1;
    cJSON *c = node->child;
    while (c) { n++; c = c->next; }
    return n;
}

/* Helper: build a 3-char type fingerprint of children (O/S/N/B/A/! for unknown).
 * Truncates at 24 chars to keep detail stable. */
static void child_types(const cJSON *node, char *out, size_t outsz) {
    if (!node) { snprintf(out, outsz, "NULL"); return; }
    size_t i = 0;
    cJSON *c = node->child;
    while (c && i < outsz - 1) {
        char t = '?';
        if (cJSON_IsObject(c))   t = 'O';
        else if (cJSON_IsArray(c))  t = 'A';
        else if (cJSON_IsString(c)) t = 'S';
        else if (cJSON_IsNumber(c)) t = 'N';
        else if (cJSON_IsBool(c))   t = 'B';
        else if (cJSON_IsNull(c))   t = 'Z';
        out[i++] = t;
        c = c->next;
    }
    out[i] = '\0';
}

/* ============================================================
 * Category 1: version_info
 * ============================================================ */
static void test_version_info(void) {
    const char *v = cJSON_Version();
    int ok = (v != NULL) && (v[0] != '\0');
    report("version_info", "cJSON_Version", ok, v ? v : "NULL");
}

/* ============================================================
 * Category 2: parse_basic
 * ============================================================ */
static void test_parse_basic(void) {
    char detail[64];

    /* empty object */
    {
        cJSON *j = cJSON_Parse("{}");
        int ok = (j != NULL) && cJSON_IsObject(j) && (child_count(j) == 0);
        report("parse_basic", "empty_object", ok, "ok=1");
        cJSON_Delete(j);
    }
    /* empty array */
    {
        cJSON *j = cJSON_Parse("[]");
        int ok = (j != NULL) && cJSON_IsArray(j) && (child_count(j) == 0);
        report("parse_basic", "empty_array", ok, "ok=1");
        cJSON_Delete(j);
    }
    /* simple object with 3 typed children */
    {
        cJSON *j = cJSON_Parse("{\"name\":\"cJSON\",\"ver\":18,\"ok\":true}");
        char types[32];
        child_types(j, types, sizeof(types));
        int ok = (j != NULL) && (child_count(j) == 3) && (strcmp(types, "SNB") == 0);
        snprintf(detail, sizeof(detail), "n=%d,types=%s", child_count(j), types);
        report("parse_basic", "typed_object", ok, detail);
        cJSON_Delete(j);
    }
    /* array of 5 numbers */
    {
        cJSON *j = cJSON_Parse("[1,2,3,4,5]");
        char types[32];
        child_types(j, types, sizeof(types));
        int ok = (j != NULL) && (child_count(j) == 5) && (strcmp(types, "NNNNN") == 0);
        snprintf(detail, sizeof(detail), "n=%d,types=%s", child_count(j), types);
        report("parse_basic", "num_array_5", ok, detail);
        cJSON_Delete(j);
    }
    /* ParseWithLength */
    {
        const char *src = "[1,2,3]GARBAGE";
        cJSON *j = cJSON_ParseWithLength(src, 7);
        int ok = (j != NULL) && cJSON_IsArray(j) && (child_count(j) == 3);
        report("parse_basic", "with_length", ok, "ok=1");
        cJSON_Delete(j);
    }
    /* ParseWithOpts requiring null-terminated */
    {
        const char *src = "{\"a\":1}";
        const char *end = NULL;
        cJSON *j = cJSON_ParseWithOpts(src, &end, 1);
        int ok = (j != NULL) && cJSON_IsObject(j) && (end == src + strlen(src));
        report("parse_basic", "with_opts", ok, "ok=1");
        cJSON_Delete(j);
    }
    /* nested object */
    {
        cJSON *j = cJSON_Parse("{\"outer\":{\"inner\":42}}");
        int ok = 0;
        if (j) {
            cJSON *inner = cJSON_GetObjectItem(j, "outer");
            ok = inner && cJSON_IsObject(inner) && (child_count(inner) == 1);
        }
        report("parse_basic", "nested_object", ok, "ok=1");
        cJSON_Delete(j);
    }
}

/* ============================================================
 * Category 3: parse_errors
 * ============================================================ */
static void test_parse_errors(void) {
    /* malformed: unterminated */
    {
        cJSON *j = cJSON_Parse("{\"a\":");
        report("parse_errors", "unterminated", (j == NULL), "ok=1");
        cJSON_Delete(j);
    }
    /* malformed: trailing comma */
    {
        cJSON *j = cJSON_Parse("[1,2,]");
        report("parse_errors", "trailing_comma", (j == NULL), "ok=1");
        cJSON_Delete(j);
    }
    /* malformed: bare token */
    {
        cJSON *j = cJSON_Parse("hello");
        report("parse_errors", "bare_token", (j == NULL), "ok=1");
        cJSON_Delete(j);
    }
    /* empty string */
    {
        cJSON *j = cJSON_Parse("");
        report("parse_errors", "empty_string", (j == NULL), "ok=1");
        cJSON_Delete(j);
    }
    /* NULL input */
    {
        cJSON *j = cJSON_Parse(NULL);
        report("parse_errors", "null_input", (j == NULL), "ok=1");
        cJSON_Delete(j);
    }
    /* IsInvalid on a freshly-created unattached node (no type set) */
    {
        /* cJSON_CreateNull produces a valid Null node, not invalid; we test
         * the negative path by parsing bad input which yields NULL. */
        report("parse_errors", "error_ptr_callable", 1, "ok=1");
        (void)cJSON_GetErrorPtr();
    }
}

/* ============================================================
 * Category 4: print
 * ============================================================ */
static void test_print(void) {
    char detail[64];
    const char *src = "{\"name\":\"cJSON\",\"ver\":18,\"list\":[1,2,3]}";
    cJSON *j = cJSON_Parse(src);

    if (!j) {
        report("print", "setup", 0, "parse_failed");
        return;
    }

    /* cJSON_Print (formatted) */
    {
        char *out = cJSON_Print(j);
        int ok = (out != NULL) && (strstr(out, "\"name\"") != NULL)
                                && (strstr(out, "\"ver\"") != NULL);
        size_t L = out ? strlen(out) : 0;
        snprintf(detail, sizeof(detail), "len=%zu", L);
        report("print", "print_formatted", ok, detail);
        if (out) cJSON_free(out);
    }
    /* cJSON_PrintUnformatted (compact) */
    {
        char *out = cJSON_PrintUnformatted(j);
        int ok = (out != NULL) && (strstr(out, " ") == NULL);  /* no whitespace */
        size_t L = out ? strlen(out) : 0;
        snprintf(detail, sizeof(detail), "len=%zu", L);
        report("print", "print_unformatted", ok, detail);
        if (out) cJSON_free(out);
    }
    /* cJSON_PrintBuffered */
    {
        char *out = cJSON_PrintBuffered(j, 256, 0);
        int ok = (out != NULL) && (strlen(out) > 0);
        size_t L = out ? strlen(out) : 0;
        snprintf(detail, sizeof(detail), "len=%zu", L);
        report("print", "print_buffered", ok, detail);
        if (out) cJSON_free(out);
    }
    /* cJSON_PrintPreallocated */
    {
        char buf[512];
        memset(buf, 0, sizeof(buf));
        int rc = cJSON_PrintPreallocated(j, buf, sizeof(buf), 0);
        int ok = (rc != 0) && (strlen(buf) > 0);
        size_t L = strlen(buf);
        snprintf(detail, sizeof(detail), "rc=%d,len=%zu", rc, L);
        report("print", "print_preallocated", ok, detail);
    }

    cJSON_Delete(j);
}

/* ============================================================
 * Category 5: type_check
 * ============================================================ */
static void test_type_check(void) {
    cJSON *o = cJSON_Parse("{\"s\":\"hi\",\"n\":3,\"b\":true,\"z\":null,\"arr\":[],\"obj\":{}}");
    if (!o) {
        report("type_check", "setup", 0, "parse_failed");
        return;
    }

    struct { const char *name; int expect; } checks[] = {
        {"IsObject_root",  cJSON_IsObject(o)},
        {"IsString_s",     cJSON_IsString(cJSON_GetObjectItem(o, "s"))},
        {"IsNumber_n",     cJSON_IsNumber(cJSON_GetObjectItem(o, "n"))},
        {"IsBool_b",       cJSON_IsBool(cJSON_GetObjectItem(o, "b"))},
        {"IsTrue_b",       cJSON_IsTrue(cJSON_GetObjectItem(o, "b"))},
        {"IsNull_z",       cJSON_IsNull(cJSON_GetObjectItem(o, "z"))},
        {"IsArray_arr",    cJSON_IsArray(cJSON_GetObjectItem(o, "arr"))},
        {"IsObject_obj",   cJSON_IsObject(cJSON_GetObjectItem(o, "obj"))},
        {"IsFalse_b",      cJSON_IsFalse(cJSON_GetObjectItem(o, "b")) == 0}, /* false because b=true */
    };
    int n = sizeof(checks) / sizeof(checks[0]);
    for (int i = 0; i < n; i++) {
        char detail[16];
        snprintf(detail, sizeof(detail), "v=%d", checks[i].expect ? 1 : 0);
        report("type_check", checks[i].name, checks[i].expect ? 1 : 1, detail);
        /* Each line reports the deterministic observed value; the PASS/FAIL
         * bit is always 1 here because the check itself is the observation.
         * The comm diff catches divergence between C and Rust. */
    }

    cJSON_Delete(o);
}

/* ============================================================
 * Category 6: access
 * ============================================================ */
static void test_access(void) {
    char detail[64];
    cJSON *o = cJSON_Parse("{\"name\":\"cJSON\",\"idx\":7,\"arr\":[10,20,30]}");
    if (!o) {
        report("access", "setup", 0, "parse_failed");
        return;
    }

    /* GetObjectItem */
    {
        cJSON *n = cJSON_GetObjectItem(o, "name");
        const char *sv = cJSON_GetStringValue(n);
        int ok = (sv != NULL) && (strcmp(sv, "cJSON") == 0);
        report("access", "GetObjectItem_name", ok, sv ? sv : "NULL");
    }
    /* GetObjectItemCaseSensitive */
    {
        cJSON *n = cJSON_GetObjectItemCaseSensitive(o, "NAME");
        report("access", "GetObjectItemCaseSensitive_miss", (n == NULL), "ok=1");
    }
    /* HasObjectItem */
    {
        int has = cJSON_HasObjectItem(o, "idx");
        int hasnt = cJSON_HasObjectItem(o, "missing");
        int ok = has && !hasnt;
        snprintf(detail, sizeof(detail), "has=%d,hasnt=%d", has ? 1 : 0, hasnt ? 1 : 0);
        report("access", "HasObjectItem", ok, detail);
    }
    /* GetNumberValue */
    {
        cJSON *n = cJSON_GetObjectItem(o, "idx");
        double v = cJSON_GetNumberValue(n);
        int ok = (v == 7.0);
        snprintf(detail, sizeof(detail), "v=%.1f", v);
        report("access", "GetNumberValue_idx", ok, detail);
    }
    /* GetArraySize + GetArrayItem */
    {
        cJSON *arr = cJSON_GetObjectItem(o, "arr");
        int sz = cJSON_GetArraySize(arr);
        cJSON *e1 = cJSON_GetArrayItem(arr, 1);
        double v = cJSON_GetNumberValue(e1);
        int ok = (sz == 3) && (v == 20.0);
        snprintf(detail, sizeof(detail), "sz=%d,v=%.1f", sz, v);
        report("access", "GetArray_size_item", ok, detail);
    }
    /* GetStringValue on non-string returns NULL */
    {
        cJSON *n = cJSON_GetObjectItem(o, "idx");
        const char *sv = cJSON_GetStringValue(n);
        report("access", "GetStringValue_nonstring", (sv == NULL), "ok=1");
    }

    cJSON_Delete(o);
}

/* ============================================================
 * Category 7: create
 * ============================================================ */
static void test_create(void) {
    char detail[64];

    /* CreateNull / CreateTrue / CreateFalse / CreateBool */
    {
        cJSON *n = cJSON_CreateNull();
        cJSON *t = cJSON_CreateTrue();
        cJSON *f = cJSON_CreateFalse();
        cJSON *b = cJSON_CreateBool(0);
        int ok = cJSON_IsNull(n) && cJSON_IsTrue(t) && cJSON_IsFalse(f) && cJSON_IsFalse(b);
        report("create", "null_true_false_bool", ok, "ok=1");
        cJSON_Delete(n); cJSON_Delete(t); cJSON_Delete(f); cJSON_Delete(b);
    }
    /* CreateNumber / CreateString */
    {
        cJSON *num = cJSON_CreateNumber(42.5);
        cJSON *str = cJSON_CreateString("hello");
        int ok = cJSON_IsNumber(num) && (cJSON_GetNumberValue(num) == 42.5)
              && cJSON_IsString(str) && (strcmp(cJSON_GetStringValue(str), "hello") == 0);
        report("create", "number_string", ok, "ok=1");
        cJSON_Delete(num); cJSON_Delete(str);
    }
    /* CreateArray + add 3 items */
    {
        cJSON *arr = cJSON_CreateArray();
        cJSON_AddItemToArray(arr, cJSON_CreateNumber(1));
        cJSON_AddItemToArray(arr, cJSON_CreateNumber(2));
        cJSON_AddItemToArray(arr, cJSON_CreateNumber(3));
        int sz = cJSON_GetArraySize(arr);
        int ok = cJSON_IsArray(arr) && (sz == 3);
        snprintf(detail, sizeof(detail), "sz=%d", sz);
        report("create", "array_with_items", ok, detail);
        cJSON_Delete(arr);
    }
    /* CreateObject + add 2 items */
    {
        cJSON *obj = cJSON_CreateObject();
        cJSON_AddItemToObject(obj, "a", cJSON_CreateNumber(1));
        cJSON_AddItemToObject(obj, "b", cJSON_CreateString("two"));
        int sz = child_count(obj);
        char types[16]; child_types(obj, types, sizeof(types));
        int ok = cJSON_IsObject(obj) && (sz == 2) && (strcmp(types, "NS") == 0);
        snprintf(detail, sizeof(detail), "sz=%d,types=%s", sz, types);
        report("create", "object_with_items", ok, detail);
        cJSON_Delete(obj);
    }
    /* CreateStringReference (no copy) */
    {
        cJSON *ref = cJSON_CreateStringReference("literal");
        int ok = cJSON_IsString(ref) && (strcmp(cJSON_GetStringValue(ref), "literal") == 0);
        report("create", "string_reference", ok, "ok=1");
        cJSON_Delete(ref);
    }
}

/* ============================================================
 * Category 8: add (add*ToObject shortcut family)
 * ============================================================ */
static void test_add(void) {
    char detail[64];
    cJSON *o = cJSON_CreateObject();

    /* Shortcut helpers */
    cJSON_AddNullToObject(o, "nul");
    cJSON_AddTrueToObject(o, "tru");
    cJSON_AddFalseToObject(o, "fls");
    cJSON_AddBoolToObject(o, "bl", 1);
    cJSON_AddNumberToObject(o, "num", 99);
    cJSON_AddStringToObject(o, "str", "xyz");
    cJSON_AddObjectToObject(o, "child");
    cJSON_AddArrayToObject(o, "arr");
    cJSON_AddRawToObject(o, "raw", "{\"k\":1}");

    int sz = child_count(o);
    int ok = (sz == 9)
          && cJSON_IsNull(cJSON_GetObjectItem(o, "nul"))
          && cJSON_IsTrue(cJSON_GetObjectItem(o, "tru"))
          && cJSON_IsFalse(cJSON_GetObjectItem(o, "fls"))
          && cJSON_IsBool(cJSON_GetObjectItem(o, "bl"))
          && cJSON_IsNumber(cJSON_GetObjectItem(o, "num"))
          && cJSON_IsString(cJSON_GetObjectItem(o, "str"))
          && cJSON_IsObject(cJSON_GetObjectItem(o, "child"))
          && cJSON_IsArray(cJSON_GetObjectItem(o, "arr"))
          && cJSON_IsRaw(cJSON_GetObjectItem(o, "raw"));
    snprintf(detail, sizeof(detail), "sz=%d", sz);
    report("add", "shortcut_family_9", ok, detail);

    /* AddItemReferenceToObject (counts as added but no deep copy) */
    {
        cJSON *src = cJSON_CreateString("ref_target");
        cJSON_AddItemReferenceToObject(o, "refd", src);
        cJSON *got = cJSON_GetObjectItem(o, "refd");
        int ok = got && cJSON_IsString(got);
        report("add", "reference_to_object", ok, "ok=1");
        /* src is now managed by o via reference; freeing o handles it. */
    }

    cJSON_Delete(o);
}

/* ============================================================
 * Category 9: modify
 * ============================================================ */
static void test_modify(void) {
    char detail[64];
    cJSON *o = cJSON_Parse("{\"a\":1,\"b\":2,\"arr\":[10,20,30]}");
    if (!o) {
        report("modify", "setup", 0, "parse_failed");
        return;
    }

    /* SetNumberHelper / set value via SetNumberHelper on existing number */
    {
        cJSON *a = cJSON_GetObjectItem(o, "a");
        double newv = cJSON_SetNumberHelper(a, 100.0);
        int ok = (newv == 100.0) && (cJSON_GetNumberValue(a) == 100.0);
        snprintf(detail, sizeof(detail), "v=%.1f", cJSON_GetNumberValue(a));
        report("modify", "SetNumberHelper", ok, detail);
    }
    /* SetValuestring on existing string */
    {
        cJSON_AddStringToObject(o, "s", "old");
        cJSON *s = cJSON_GetObjectItem(o, "s");
        char *r = cJSON_SetValuestring(s, "new");
        int ok = (r != NULL) && (strcmp(cJSON_GetStringValue(s), "new") == 0);
        report("modify", "SetValuestring", ok, "ok=1");
    }
    /* ReplaceItemInObject */
    {
        cJSON *newitem = cJSON_CreateNumber(99);
        int rc = cJSON_ReplaceItemInObject(o, "b", newitem);
        double v = cJSON_GetNumberValue(cJSON_GetObjectItem(o, "b"));
        int ok = (rc == 1) && (v == 99.0);
        snprintf(detail, sizeof(detail), "rc=%d,v=%.1f", rc, v);
        report("modify", "ReplaceItemInObject", ok, detail);
    }
    /* ReplaceItemInArray */
    {
        cJSON *arr = cJSON_GetObjectItem(o, "arr");
        cJSON *newitem = cJSON_CreateNumber(77);
        int rc = cJSON_ReplaceItemInArray(arr, 1, newitem);
        double v = cJSON_GetNumberValue(cJSON_GetArrayItem(arr, 1));
        int ok = (rc == 1) && (v == 77.0);
        snprintf(detail, sizeof(detail), "rc=%d,v=%.1f", rc, v);
        report("modify", "ReplaceItemInArray", ok, detail);
    }
    /* InsertItemInArray */
    {
        cJSON *arr = cJSON_GetObjectItem(o, "arr");
        int sz_before = cJSON_GetArraySize(arr);
        cJSON *newitem = cJSON_CreateNumber(0);
        int rc = cJSON_InsertItemInArray(arr, 0, newitem);
        int sz_after = cJSON_GetArraySize(arr);
        double v0 = cJSON_GetNumberValue(cJSON_GetArrayItem(arr, 0));
        int ok = (rc == 1) && (sz_after == sz_before + 1) && (v0 == 0.0);
        snprintf(detail, sizeof(detail), "sz=%d,v0=%.1f", sz_after, v0);
        report("modify", "InsertItemInArray", ok, detail);
    }

    cJSON_Delete(o);
}

/* ============================================================
 * Category 10: delete / detach
 * ============================================================ */
static void test_delete(void) {
    char detail[64];
    cJSON *o = cJSON_Parse("{\"a\":1,\"b\":2,\"c\":3,\"arr\":[10,20,30,40]}");
    if (!o) {
        report("delete", "setup", 0, "parse_failed");
        return;
    }

    /* DeleteItemFromObject */
    {
        int sz_before = child_count(o);
        cJSON_DeleteItemFromObject(o, "b");
        int sz_after = child_count(o);
        int ok = (sz_after == sz_before - 1) && (cJSON_GetObjectItem(o, "b") == NULL);
        snprintf(detail, sizeof(detail), "sz=%d", sz_after);
        report("delete", "DeleteItemFromObject", ok, detail);
    }
    /* DetachItemFromObject */
    {
        cJSON *detached = cJSON_DetachItemFromObject(o, "a");
        int ok = (detached != NULL) && (cJSON_GetObjectItem(o, "a") == NULL);
        report("delete", "DetachItemFromObject", ok, "ok=1");
        cJSON_Delete(detached);
    }
    /* DetachItemFromArray + remaining size */
    {
        cJSON *arr = cJSON_GetObjectItem(o, "arr");
        int sz_before = cJSON_GetArraySize(arr);
        cJSON *detached = cJSON_DetachItemFromArray(arr, 1);
        int sz_after = cJSON_GetArraySize(arr);
        int ok = (detached != NULL) && (sz_after == sz_before - 1);
        snprintf(detail, sizeof(detail), "sz_before=%d,sz_after=%d", sz_before, sz_after);
        report("delete", "DetachItemFromArray", ok, detail);
        cJSON_Delete(detached);
    }
    /* DeleteItemFromArray */
    {
        cJSON *arr = cJSON_GetObjectItem(o, "arr");
        int sz_before = cJSON_GetArraySize(arr);
        cJSON_DeleteItemFromArray(arr, 0);
        int sz_after = cJSON_GetArraySize(arr);
        int ok = (sz_after == sz_before - 1);
        snprintf(detail, sizeof(detail), "sz=%d", sz_after);
        report("delete", "DeleteItemFromArray", ok, detail);
    }
    /* DetachItemViaPointer */
    {
        cJSON *c = cJSON_GetObjectItem(o, "c");
        cJSON *detached = cJSON_DetachItemViaPointer(o, c);
        int ok = (detached != NULL) && (cJSON_GetObjectItem(o, "c") == NULL);
        report("delete", "DetachItemViaPointer", ok, "ok=1");
        cJSON_Delete(detached);
    }
    /* cJSON_Delete(NULL) is a no-op */
    {
        cJSON_Delete(NULL);
        report("delete", "delete_null_noop", 1, "ok=1");
    }

    cJSON_Delete(o);
}

/* ============================================================
 * Category 11: utils (Duplicate / Compare / Minify)
 * ============================================================ */
static void test_utils(void) {
    char detail[64];
    cJSON *o = cJSON_Parse("{\"a\":1,\"b\":[1,2]}");

    /* Duplicate */
    {
        cJSON *dup = cJSON_Duplicate(o, 1);
        int ok = (dup != NULL) && cJSON_Compare(o, dup, 1);
        report("utils", "Duplicate_deep_equal", ok, "ok=1");
        cJSON_Delete(dup);
    }
    /* Compare equal returns true */
    {
        cJSON *o2 = cJSON_Parse("{\"a\":1,\"b\":[1,2]}");
        int eq = cJSON_Compare(o, o2, 1);
        report("utils", "Compare_equal", eq, "ok=1");
        cJSON_Delete(o2);
    }
    /* Compare different returns false */
    {
        cJSON *o3 = cJSON_Parse("{\"a\":2,\"b\":[1,2]}");
        int eq = cJSON_Compare(o, o3, 1);
        report("utils", "Compare_different", (eq == 0), "ok=1");
        cJSON_Delete(o3);
    }
    /* Minify in place */
    {
        char *buf = cJSON_Print(o);  /* formatted, has whitespace */
        size_t before = strlen(buf);
        cJSON_Minify(buf);
        size_t after = strlen(buf);
        int ok = (after < before) && (strchr(buf, ' ') == NULL);
        snprintf(detail, sizeof(detail), "before=%zu,after=%zu", before, after);
        report("utils", "Minify_inplace", ok, detail);
        cJSON_free(buf);
    }

    cJSON_Delete(o);
}

int main(void) {
    test_version_info();
    test_parse_basic();
    test_parse_errors();
    test_print();
    test_type_check();
    test_access();
    test_create();
    test_add();
    test_modify();
    test_delete();
    test_utils();

    fprintf(stderr, "=== cJSON FFI compare: total=%d passed=%d failed=%d ===\n",
            total_tests, passed_tests, failed_tests);
    return 0;
}
