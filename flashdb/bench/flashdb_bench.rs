//! Framework-provided Rust benchmark for the FlashDB C→Rust evaluation.
//!
//! This is a 1:1 port of `flashdb/tests/benchmark/bench_main.c`. Instead of
//! calling the original C library it calls the **converted** `rust_flashdb`
//! crate's C-compatible FFI (`#[no_mangle] pub unsafe extern "C" fn ...`),
//! so the workload is identical to the C baseline and the resulting numbers
//! are directly comparable.
//!
//! It is compiled as a bench target *inside* the converted crate (dropped into
//! `rust-flashdb/benches/flashdb_bench.rs` with `harness = false`), so it can
//! reach the crate's own FFI symbols by path.
//!
//! Output format intentionally matches `scripts/eval-performance.sh`'s parser:
//!   `"  <name> | <n> ops | <us> us | <ops/s> ops/s | <us/op> us/op"`
//! where `<name>` is identical to `bench_main.c` (e.g. `KVDB set (string)`),
//! producing the same metric keys for both C and Rust.

#![allow(non_snake_case)]
#![allow(non_upper_case_globals)]
#![allow(dead_code)]
#![allow(unused_assignments)]
#![allow(unused_mut)]
#![allow(clippy::missing_safety_doc)]

use std::ffi::CString;
use std::fs;
use std::mem::MaybeUninit;
use std::time::Instant;

// The converted crate. FFI lives in these modules (c2rust lays it out per-file).
use rust_flashdb::fdb_kvdb as kv;
use rust_flashdb::fdb_tsdb as ts;
use rust_flashdb::fdb_utils as ut;

// ---- Tunables: mirror bench_main.c #defines exactly ----
const BENCH_SEC_SIZE: u32 = 4096;
const BENCH_KVDB_SECS: u32 = 128;
const BENCH_TSDB_SECS: u32 = 128;
const BENCH_KV_COUNT: u32 = 1000;
const BENCH_KV_BLOB_SIZE: usize = 128;
const BENCH_TSL_COUNT: u32 = 2000;
const BENCH_TSL_BLOB_SIZE: usize = 64;
const BENCH_ITER_COUNT: i32 = 3;

const KVDB_PATH: &str = "bench_kvdb";
const TSDB_PATH: &str = "bench_tsdb";

// Monotonic time source for TSDB (mirrors bench_get_time: 1, 2, 3, ...).
static mut BENCH_CUR_TIME: i32 = 0;

// ---- Timing helpers (same shape as the C bench_start/bench_end/bench_print) ----

fn elapsed_us_since(start: Instant) -> f64 {
    start.elapsed().as_secs_f64() * 1e6_f64
}

fn bench_print(name: &str, count: u32, elapsed_us: f64) {
    let ops_per_sec = if elapsed_us > 0.0 {
        count as f64 / (elapsed_us / 1e6_f64)
    } else {
        0.0
    };
    let us_per_op = if count > 0 {
        elapsed_us / count as f64
    } else {
        0.0
    };
    println!(
        "  {:<30} | {:>6} ops | {:>9.1} us | {:>8.1} ops/s | {:>7.2} us/op",
        name, count, elapsed_us, ops_per_sec, us_per_op
    );
}

fn print_separator() {
    println!(
        "  {:<30} | {:<8} | {:<11} | {:<10} | {:<10}",
        "Benchmark", "Count", "Elapsed", "Ops/s", "Us/op"
    );
    println!(
        "  {:<30}-+-{}-+-{}-+-{}-+-{}",
        "------------------------------",
        "--------",
        "-----------",
        "----------",
        "----------"
    );
}

// ---- No-op lock callbacks (the bench is single-threaded) ----

unsafe extern "C" fn nop_lock(_db: kv::fdb_db_t) {}
unsafe extern "C" fn nop_unlock(_db: kv::fdb_db_t) {}

// NOTE on building locally (macOS): the transpiled crate calls libc `assert()`;
// an old nightly sometimes fails to resolve `__assert_fail` from libSystem when
// linking the bench binary. On CI (Linux/glibc) the real libc symbol resolves
// fine (the equivalence build already links the same crate). To iterate on this
// bench on macOS, build with:
//   RUSTFLAGS='-C link-arg=-Wl,-undefined,dynamic_lookup' cargo build --release --bench flashdb_bench

unsafe extern "C" fn bench_get_time() -> ts::fdb_time_t {
    BENCH_CUR_TIME += 1;
    BENCH_CUR_TIME
}

// TSDB iteration callback: counts every TSL, returns false = keep iterating.
static mut TSDB_ITER_COUNT: u32 = 0;
unsafe extern "C" fn tsl_iter_cb(_tsl: ts::fdb_tsl_t, _arg: *mut core::ffi::c_void) -> bool {
    TSDB_ITER_COUNT += 1;
    false
}

// ---- Workload: KVDB (mirrors bench_kvdb_* in bench_main.c) ----

unsafe fn bench_kvdb_set_string(db: kv::fdb_kvdb_t, count: u32) {
    let start = Instant::now();
    for i in 0..count {
        let key = CString::new(format!("str_{}", i)).unwrap();
        let val = CString::new(format!("val_{}", i)).unwrap();
        kv::fdb_kv_set(db, key.as_ptr(), val.as_ptr());
    }
    bench_print("KVDB set (string)", count, elapsed_us_since(start));
}

unsafe fn bench_kvdb_get_string(db: kv::fdb_kvdb_t, count: u32) {
    let start = Instant::now();
    for i in 0..count {
        let key = CString::new(format!("str_{}", i)).unwrap();
        kv::fdb_kv_get(db, key.as_ptr());
    }
    bench_print("KVDB get (string)", count, elapsed_us_since(start));
}

unsafe fn bench_kvdb_set_blob(db: kv::fdb_kvdb_t, count: u32, blob_size: usize) {
    let mut buf = vec![0xAB_u8; blob_size];
    // c2rust emits fdb_blob three times (one per module), identical #[repr(C)]
    // layout. Use the fdb_utils definition as the canonical home and cast the
    // pointer for the kvdb-flavoured call site.
    let mut blob: ut::fdb_blob = MaybeUninit::zeroed().assume_init();
    let blob_ut = &mut blob as *mut ut::fdb_blob;
    let blob_kv = blob_ut as kv::fdb_blob_t;
    let start = Instant::now();
    for i in 0..count {
        let key = CString::new(format!("blob_{}", i)).unwrap();
        ut::fdb_blob_make(
            blob_ut,
            buf.as_ptr() as *const core::ffi::c_void,
            blob_size,
        );
        kv::fdb_kv_set_blob(db, key.as_ptr(), blob_kv);
    }
    bench_print("KVDB set (blob)", count, elapsed_us_since(start));
}

unsafe fn bench_kvdb_get_blob(db: kv::fdb_kvdb_t, count: u32, blob_size: usize) {
    let mut buf = vec![0u8; blob_size];
    let mut blob: ut::fdb_blob = MaybeUninit::zeroed().assume_init();
    let blob_ut = &mut blob as *mut ut::fdb_blob;
    let blob_kv = blob_ut as kv::fdb_blob_t;
    let start = Instant::now();
    for i in 0..count {
        let key = CString::new(format!("blob_{}", i)).unwrap();
        ut::fdb_blob_make(
            blob_ut,
            buf.as_mut_ptr() as *const core::ffi::c_void,
            blob_size,
        );
        kv::fdb_kv_get_blob(db, key.as_ptr(), blob_kv);
    }
    bench_print("KVDB get (blob)", count, elapsed_us_since(start));
}

unsafe fn bench_kvdb_update_string(db: kv::fdb_kvdb_t, count: u32) {
    let start = Instant::now();
    for i in 0..count {
        let key = CString::new(format!("str_{}", i)).unwrap();
        let val = CString::new(format!("upd_{}", i)).unwrap();
        kv::fdb_kv_set(db, key.as_ptr(), val.as_ptr());
    }
    bench_print("KVDB update (string)", count, elapsed_us_since(start));
}

unsafe fn bench_kvdb_iterate(db: kv::fdb_kvdb_t, expected_count: u32) {
    let mut iter: kv::fdb_kv_iterator = MaybeUninit::zeroed().assume_init();
    let iter_ptr = &mut iter as *mut kv::fdb_kv_iterator;
    kv::fdb_kv_iterator_init(db, iter_ptr);
    let start = Instant::now();
    let mut found = 0_u32;
    while kv::fdb_kv_iterate(db, iter_ptr) {
        found += 1;
    }
    let elapsed = elapsed_us_since(start);
    bench_print("KVDB iterate all", found, elapsed);
    println!("    (found {}, expected {})", found, expected_count);
}

unsafe fn bench_kvdb_delete(db: kv::fdb_kvdb_t, count: u32) {
    let start = Instant::now();
    for i in 0..count {
        let key = CString::new(format!("str_{}", i)).unwrap();
        kv::fdb_kv_del(db, key.as_ptr());
    }
    bench_print("KVDB delete", count, elapsed_us_since(start));
}

// ---- Workload: TSDB (mirrors bench_tsdb_* in bench_main.c) ----

unsafe fn bench_tsdb_append(db: ts::fdb_tsdb_t, count: u32, blob_size: usize) {
    let mut buf = vec![0xCD_u8; blob_size];
    let mut blob: ut::fdb_blob = MaybeUninit::zeroed().assume_init();
    let blob_ut = &mut blob as *mut ut::fdb_blob;
    let blob_ts = blob_ut as ts::fdb_blob_t;
    let start = Instant::now();
    for _ in 0..count {
        ut::fdb_blob_make(
            blob_ut,
            buf.as_ptr() as *const core::ffi::c_void,
            blob_size,
        );
        ts::fdb_tsl_append(db, blob_ts);
    }
    bench_print("TSDB append", count, elapsed_us_since(start));
}

unsafe fn bench_tsdb_iter(db: ts::fdb_tsdb_t, expected_count: u32) {
    TSDB_ITER_COUNT = 0;
    let cb: ts::fdb_tsl_cb = Some(tsl_iter_cb);
    let start = Instant::now();
    ts::fdb_tsl_iter(db, cb, core::ptr::null_mut());
    let found = TSDB_ITER_COUNT;
    let elapsed = elapsed_us_since(start);
    bench_print("TSDB iterate all", found, elapsed);
    println!("    (found {}, expected {})", found, expected_count);
}

unsafe fn bench_tsdb_iter_by_time(
    db: ts::fdb_tsdb_t,
    from: ts::fdb_time_t,
    to: ts::fdb_time_t,
    expected_count: u32,
) {
    TSDB_ITER_COUNT = 0;
    let cb: ts::fdb_tsl_cb = Some(tsl_iter_cb);
    let start = Instant::now();
    ts::fdb_tsl_iter_by_time(db, from, to, cb, core::ptr::null_mut());
    let found = TSDB_ITER_COUNT;
    let elapsed = elapsed_us_since(start);
    bench_print("TSDB iter by time", found, elapsed);
    println!("    (found {}, expected {})", found, expected_count);
}

unsafe fn bench_tsdb_query_count(db: ts::fdb_tsdb_t, from: ts::fdb_time_t, to: ts::fdb_time_t) {
    let start = Instant::now();
    let count = ts::fdb_tsl_query_count(db, from, to, ts::FDB_TSL_WRITE);
    let elapsed = elapsed_us_since(start);
    bench_print("TSDB query count", count as u32, elapsed);
}

// ---- Directory helpers ----

fn cleanup_dir(path: &str) {
    let _ = fs::remove_dir_all(path);
}

// ---- main (mirrors bench_main.c::main) ----

fn main() {
    // Rust's `println!` writes through a LineWriter that flushes on every
    // newline, so unlike the C bench (whose printf to a pipe was fully
    // buffered) output is not lost if this process is killed by a timeout.
    // The explicit flush before exit below is just belt-and-suspenders.

    cleanup_dir(KVDB_PATH);
    cleanup_dir(TSDB_PATH);
    let _ = fs::create_dir_all(KVDB_PATH);
    let _ = fs::create_dir_all(TSDB_PATH);

    let kvdb_size: u32 = BENCH_SEC_SIZE * BENCH_KVDB_SECS;
    let tsdb_size: u32 = BENCH_SEC_SIZE * BENCH_TSDB_SECS;

    println!();
    println!("============================================================");
    println!("  FlashDB Rust (converted crate) Performance Benchmark");
    println!(
        "  Sector size: {} bytes, KVDB sectors: {}, TSDB sectors: {}",
        BENCH_SEC_SIZE, BENCH_KVDB_SECS, BENCH_TSDB_SECS
    );
    println!("  FDB_WRITE_GRAN: 1, File mode: POSIX");
    println!("============================================================");
    println!();

    // ---------------- KVDB ----------------
    unsafe {
        BENCH_CUR_TIME = 0;
        let mut kvdb: kv::fdb_kvdb = MaybeUninit::zeroed().assume_init();
        let db = &mut kvdb as *mut kv::fdb_kvdb;

        let mut sec_size = BENCH_SEC_SIZE;
        let mut kvdb_max = kvdb_size;
        let mut file_mode: bool = true;

        kv::fdb_kvdb_control(
            db,
            kv::FDB_KVDB_CTRL_SET_SEC_SIZE,
            &mut sec_size as *mut u32 as *mut core::ffi::c_void,
        );
        kv::fdb_kvdb_control(
            db,
            kv::FDB_KVDB_CTRL_SET_MAX_SIZE,
            &mut kvdb_max as *mut u32 as *mut core::ffi::c_void,
        );
        kv::fdb_kvdb_control(
            db,
            kv::FDB_KVDB_CTRL_SET_FILE_MODE,
            &mut file_mode as *mut bool as *mut core::ffi::c_void,
        );
        kv::fdb_kvdb_control(
            db,
            kv::FDB_KVDB_CTRL_SET_LOCK,
            nop_lock as *mut core::ffi::c_void,
        );
        kv::fdb_kvdb_control(
            db,
            kv::FDB_KVDB_CTRL_SET_UNLOCK,
            nop_unlock as *mut core::ffi::c_void,
        );

        let name = CString::new("bench_kv").unwrap();
        let path = CString::new(KVDB_PATH).unwrap();
        let result = kv::fdb_kvdb_init(
            db,
            name.as_ptr(),
            path.as_ptr(),
            core::ptr::null_mut(),
            core::ptr::null_mut(),
        );
        if result != kv::FDB_NO_ERR {
            eprintln!("KVDB init failed: {}", result);
            std::process::exit(1);
        }

        println!("--- KVDB Benchmarks ---");
        println!();
        print_separator();

        for run in 0..BENCH_ITER_COUNT {
            println!();
            println!("  [Run {}/{}]", run + 1, BENCH_ITER_COUNT);
            kv::fdb_kv_set_default(db);
            bench_kvdb_set_string(db, BENCH_KV_COUNT);
            bench_kvdb_get_string(db, BENCH_KV_COUNT);
            bench_kvdb_set_blob(db, BENCH_KV_COUNT, BENCH_KV_BLOB_SIZE);
            bench_kvdb_get_blob(db, BENCH_KV_COUNT, BENCH_KV_BLOB_SIZE);
            bench_kvdb_update_string(db, BENCH_KV_COUNT);
            bench_kvdb_iterate(db, BENCH_KV_COUNT + BENCH_KV_COUNT);
            bench_kvdb_delete(db, BENCH_KV_COUNT);
        }

        kv::fdb_kvdb_deinit(db);
    }

    // ---------------- TSDB ----------------
    unsafe {
        println!();
        println!("--- TSDB Benchmarks ---");
        println!();
        print_separator();

        let mut tsdb: ts::fdb_tsdb = MaybeUninit::zeroed().assume_init();
        let db = &mut tsdb as *mut ts::fdb_tsdb;

        let mut sec_size = BENCH_SEC_SIZE;
        let mut tsdb_max = tsdb_size;
        let mut file_mode: bool = true;

        ts::fdb_tsdb_control(
            db,
            ts::FDB_TSDB_CTRL_SET_SEC_SIZE,
            &mut sec_size as *mut u32 as *mut core::ffi::c_void,
        );
        ts::fdb_tsdb_control(
            db,
            ts::FDB_TSDB_CTRL_SET_MAX_SIZE,
            &mut tsdb_max as *mut u32 as *mut core::ffi::c_void,
        );
        ts::fdb_tsdb_control(
            db,
            ts::FDB_TSDB_CTRL_SET_FILE_MODE,
            &mut file_mode as *mut bool as *mut core::ffi::c_void,
        );
        ts::fdb_tsdb_control(
            db,
            ts::FDB_TSDB_CTRL_SET_LOCK,
            nop_lock as *mut core::ffi::c_void,
        );
        ts::fdb_tsdb_control(
            db,
            ts::FDB_TSDB_CTRL_SET_UNLOCK,
            nop_unlock as *mut core::ffi::c_void,
        );

        let name = CString::new("bench_ts").unwrap();
        let path = CString::new(TSDB_PATH).unwrap();
        let result = ts::fdb_tsdb_init(
            db,
            name.as_ptr(),
            path.as_ptr(),
            Some(bench_get_time),
            (BENCH_TSL_BLOB_SIZE * 2) as usize,
            core::ptr::null_mut(),
        );
        if result != ts::FDB_NO_ERR {
            eprintln!("TSDB init failed: {}", result);
            std::process::exit(1);
        }

        for run in 0..BENCH_ITER_COUNT {
            println!();
            println!("  [Run {}/{}]", run + 1, BENCH_ITER_COUNT);
            ts::fdb_tsl_clean(db);
            BENCH_CUR_TIME = 0;
            let ts_start: ts::fdb_time_t = 1;
            bench_tsdb_append(db, BENCH_TSL_COUNT, BENCH_TSL_BLOB_SIZE);
            let ts_end: ts::fdb_time_t = BENCH_TSL_COUNT as i32 + 1;
            bench_tsdb_iter(db, BENCH_TSL_COUNT);
            bench_tsdb_iter_by_time(db, ts_start, ts_end, BENCH_TSL_COUNT);
            bench_tsdb_query_count(db, ts_start, ts_end);
        }

        ts::fdb_tsdb_deinit(db);
    }

    cleanup_dir(KVDB_PATH);
    cleanup_dir(TSDB_PATH);

    println!();
    println!("============================================================");
    println!("  Benchmark complete.");
    println!("============================================================");
    println!();

    // Make sure nothing is stuck in a buffer if we're piped.
    use std::io::Write;
    let _ = std::io::stdout().flush();
}
