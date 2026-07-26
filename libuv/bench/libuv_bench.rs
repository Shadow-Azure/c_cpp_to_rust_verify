//! libuv_bench.rs — Rust FFI performance benchmark.
//!
//! Mirrors libuv/bench/c/libuv_bench.c one-to-one: it measures the SAME three
//! operations (timer_throughput, loop_overhead, handle_init) by calling the
//! converted crate's #[no_mangle] FFI exports, so the C and Rust metrics share
//! a format and are directly comparable by aggregate-score.py.
//!
//! The calls go through `extern "C"` blocks bound to the crate's own
//! `#[no_mangle]` symbols (the bench links the crate rlib). This decouples the
//! bench from the crate's internal module layout, which varies between
//! conversion runs.
//!
//! Required FFI exports: uv_default_loop, uv_loop_init, uv_loop_close, uv_run,
//! uv_timer_init, uv_timer_start, uv_timer_stop, uv_close. If the conversion
//! omitted any of these, `cargo bench` fails to LINK and performance.sh reports
//! "Rust benchmark build/run failed" (perf = 0). That is the intended signal:
//! the performance of a port whose event-loop entry points are missing cannot
//! be measured. Once the conversion covers src/unix/core.c + src/unix/loop.c +
//! src/uv-common.c, this benchmark yields real metrics automatically — no
//! further changes needed here.

use std::io::Write;
use std::time::Instant;

const N_OPS: usize = 10000;

// uv_run_mode values (libuv public enum, stable across versions).
const UV_RUN_DEFAULT: core::ffi::c_int = 0;
const UV_RUN_NOWAIT: core::ffi::c_int = 2;

type LoopPtr = *mut core::ffi::c_void;
type HandlePtr = *mut core::ffi::c_void;
type TimerCb = Option<unsafe extern "C" fn(HandlePtr)>;
type CloseCb = Option<unsafe extern "C" fn(HandlePtr)>;

// Opaque, sufficiently-aligned storage for a uv_timer_t allocated on the
// stack. uv_timer_t is well under 256 bytes on every platform libuv targets;
// 16-byte alignment covers its natural alignment. Using a byte buffer keeps
// the bench independent of the crate's (variable) struct definitions.
#[repr(C, align(16))]
struct HandleBuf([u8; 256]);

extern "C" {
    fn uv_default_loop() -> LoopPtr;
    fn uv_loop_init(loop_: LoopPtr) -> core::ffi::c_int;
    fn uv_loop_close(loop_: LoopPtr) -> core::ffi::c_int;
    fn uv_run(loop_: LoopPtr, mode: core::ffi::c_int) -> core::ffi::c_int;
    fn uv_timer_init(loop_: LoopPtr, handle: HandlePtr) -> core::ffi::c_int;
    fn uv_timer_start(
        handle: HandlePtr,
        cb: TimerCb,
        timeout: u64,
        repeat: u64,
    ) -> core::ffi::c_int;
    fn uv_timer_stop(handle: HandlePtr) -> core::ffi::c_int;
    fn uv_close(handle: HandlePtr, close_cb: CloseCb);
}

unsafe extern "C" fn timer_close_cb(handle: HandlePtr) {
    // Matches the C benchmark: each fired timer closes itself.
    uv_close(handle, None);
}

unsafe extern "C" fn noop_close_cb(_handle: HandlePtr) {}

fn print_result(name: &str, n_ops: usize, elapsed_us: f64) {
    let ops_per_s = n_ops as f64 / (elapsed_us / 1e6);
    let us_per_op = elapsed_us / n_ops as f64;
    // Same format as libuv_bench.c — parsed by performance.sh:parse_metrics.
    println!(
        "  {} | {} ops | {:.1} us | {:.1} ops/s | {:.2} us/op",
        name, n_ops, elapsed_us, ops_per_s, us_per_op
    );
    // Flush so output is captured even if the loop later hangs.
    let _ = std::io::stdout().flush();
}

// --- timer_throughput: create N timers with 0ms timeout, run loop ---
fn bench_timer_throughput(loop_: LoopPtr) {
    let mut timers: Vec<HandleBuf> = (0..N_OPS).map(|_| HandleBuf([0u8; 256])).collect();
    let start = Instant::now();
    unsafe {
        for t in timers.iter_mut() {
            uv_timer_init(loop_, t as *mut _ as HandlePtr);
            uv_timer_start(t as *mut _ as HandlePtr, Some(timer_close_cb), 0, 0);
        }
        uv_run(loop_, UV_RUN_DEFAULT);
    }
    print_result(
        "timer_throughput",
        N_OPS,
        start.elapsed().as_secs_f64() * 1e6,
    );
}

// --- loop_overhead: run an empty loop N times (non-blocking) ---
fn bench_loop_overhead(loop_: LoopPtr) {
    let start = Instant::now();
    unsafe {
        for _ in 0..N_OPS {
            uv_run(loop_, UV_RUN_NOWAIT);
        }
    }
    print_result("loop_overhead", N_OPS, start.elapsed().as_secs_f64() * 1e6);
}

// --- handle_init: init + close N handles ---
fn bench_handle_init(loop_: LoopPtr) {
    let mut timers: Vec<HandleBuf> = (0..N_OPS).map(|_| HandleBuf([0u8; 256])).collect();
    let start = Instant::now();
    unsafe {
        for t in timers.iter_mut() {
            uv_timer_init(loop_, t as *mut _ as HandlePtr);
            uv_close(t as *mut _ as HandlePtr, Some(noop_close_cb));
        }
        uv_run(loop_, UV_RUN_DEFAULT);
    }
    print_result("handle_init", N_OPS, start.elapsed().as_secs_f64() * 1e6);
}

fn main() {
    let loop_ = unsafe { uv_default_loop() };
    if loop_.is_null() {
        eprintln!("FATAL: uv_default_loop() returned NULL");
        std::process::exit(1);
    }

    println!("libuv Rust FFI benchmark");
    bench_timer_throughput(loop_);
    bench_loop_overhead(loop_);
    bench_handle_init(loop_);

    unsafe {
        uv_loop_close(loop_);
    }
}
