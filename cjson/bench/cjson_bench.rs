//! cjson_bench.rs — Rust FFI performance benchmark.
//!
//! Mirrors cjson/bench/c/cjson_bench.c one-to-one: measures the SAME four
//! operations (parse_small, parse_large, print_unformatted, traverse) by
//! calling the converted crate's #[no_mangle] FFI exports, so the C and
//! Rust metrics share a format and are directly comparable by
//! aggregate-score.py.
//!
//! Required FFI exports: cJSON_Parse, cJSON_Delete, cJSON_PrintUnformatted,
//! cJSON_free, cJSON_GetArraySize, cJSON_GetArrayItem, cJSON_GetObjectItem,
//! cJSON_IsNumber, cJSON_GetNumberValue. If the conversion omitted any of
//! these, `cargo bench` fails to LINK and performance.sh reports "Rust
//! benchmark build/run failed" (perf = 0). That is the intended signal.

use std::ffi::CString;
use std::io::Write;
use std::time::Instant;

const N_SMALL: usize = 10000;
const N_LARGE: usize = 1000;

// cJSON is an opaque struct to us — we hold it as a raw pointer.
type CjsonPtr = *mut core::ffi::c_void;
type CharPtr = *mut core::ffi::c_char;

extern "C" {
    fn cJSON_Parse(value: *const core::ffi::c_char) -> CjsonPtr;
    fn cJSON_Delete(item: CjsonPtr);
    fn cJSON_PrintUnformatted(item: CjsonPtr) -> CharPtr;
    fn cJSON_free(object: *mut core::ffi::c_void);
    fn cJSON_GetArraySize(array: CjsonPtr) -> core::ffi::c_int;
    fn cJSON_GetArrayItem(array: CjsonPtr, index: core::ffi::c_int) -> CjsonPtr;
    fn cJSON_GetObjectItem(
        object: CjsonPtr,
        string: *const core::ffi::c_char,
    ) -> CjsonPtr;
    fn cJSON_IsNumber(item: CjsonPtr) -> core::ffi::c_int;
    fn cJSON_GetNumberValue(item: CjsonPtr) -> f64;
}

fn print_result(name: &str, n_ops: usize, elapsed_us: f64) {
    let ops_per_s = n_ops as f64 / (elapsed_us / 1e6);
    let us_per_op = elapsed_us / n_ops as f64;
    // Same format as cjson_bench.c — parsed by performance.sh:parse_metrics.
    println!(
        "  {} | {} ops | {:.1} us | {:.1} ops/s | {:.2} us/op",
        name, n_ops, elapsed_us, ops_per_s, us_per_op
    );
    let _ = std::io::stdout().flush();
}

// Sample small flat JSON object — identical bytes to the C benchmark.
const SMALL_JSON: &str =
    "{\"name\":\"cJSON\",\"ver\":1.7,\"ok\":true,\"count\":42,\"ratio\":3.14,\"flag\":\"yes\",\"tag\":\"bench\",\"id\":7,\"active\":false,\"score\":100}";

// Build the same 1000-element array document the C benchmark builds.
fn build_large_json(n: usize) -> String {
    let mut s = String::with_capacity(16 * n);
    s.push('[');
    for i in 0..n {
        if i > 0 {
            s.push(',');
        }
        s.push_str("{\"x\":");
        s.push_str(&i.to_string());
        s.push_str(",\"y\":");
        s.push_str(&(i * 2).to_string());
        s.push_str(",\"z\":");
        s.push_str(&(i * 3).to_string());
        s.push('}');
    }
    s.push(']');
    s
}

fn bench_parse_small(src: &CString) {
    let start = Instant::now();
    unsafe {
        for _ in 0..N_SMALL {
            let j = cJSON_Parse(src.as_ptr());
            cJSON_Delete(j);
        }
    }
    print_result("parse_small", N_SMALL, start.elapsed().as_secs_f64() * 1e6);
}

fn bench_parse_large(src: &CString) {
    let start = Instant::now();
    unsafe {
        for _ in 0..N_LARGE {
            let j = cJSON_Parse(src.as_ptr());
            cJSON_Delete(j);
        }
    }
    print_result("parse_large", N_LARGE, start.elapsed().as_secs_f64() * 1e6);
}

fn bench_print_unformatted(src: &CString) {
    let j = unsafe { cJSON_Parse(src.as_ptr()) };
    if j.is_null() {
        eprintln!("FATAL: parse failed in print_unformatted setup");
        return;
    }
    let start = Instant::now();
    unsafe {
        for _ in 0..N_LARGE {
            let out = cJSON_PrintUnformatted(j);
            if !out.is_null() {
                cJSON_free(out as *mut core::ffi::c_void);
            }
        }
    }
    print_result(
        "print_unformatted",
        N_LARGE,
        start.elapsed().as_secs_f64() * 1e6,
    );
    unsafe { cJSON_Delete(j) };
}

fn bench_traverse(src: &CString) {
    let j = unsafe { cJSON_Parse(src.as_ptr()) };
    if j.is_null() {
        eprintln!("FATAL: parse failed in traverse setup");
        return;
    }
    let x_key = CString::new("x").unwrap();
    let start = Instant::now();
    let mut sink: f64 = 0.0;
    unsafe {
        for _ in 0..N_LARGE {
            let sz = cJSON_GetArraySize(j);
            for i in 0..sz {
                let child = cJSON_GetArrayItem(j, i);
                if !child.is_null() {
                    let x = cJSON_GetObjectItem(child, x_key.as_ptr());
                    if !x.is_null() && cJSON_IsNumber(x) != 0 {
                        sink += cJSON_GetNumberValue(x);
                    }
                }
            }
        }
    }
    std::hint::black_box(sink);
    print_result("traverse", N_LARGE, start.elapsed().as_secs_f64() * 1e6);
    unsafe { cJSON_Delete(j) };
}

fn main() {
    // Warm up to avoid first-call allocation noise dominating.
    unsafe {
        let small = CString::new(SMALL_JSON).unwrap();
        let warm = cJSON_Parse(small.as_ptr());
        cJSON_Delete(warm);
    }

    let small = CString::new(SMALL_JSON).unwrap();
    let large_string = build_large_json(1000);
    let large = CString::new(large_string).expect("large JSON contains NUL");

    println!("cJSON Rust FFI benchmark");
    bench_parse_small(&small);
    bench_parse_large(&large);
    bench_print_unformatted(&large);
    bench_traverse(&large);
}
