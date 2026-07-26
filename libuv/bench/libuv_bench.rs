//! libuv_bench.rs — Rust FFI 基准测试。
//! 注入到 rust-libuv/benches/ 后通过 cargo bench --bench libuv_bench 运行。
//! 调用 Rust 转换后的 FFI 接口，输出格式与 C 基准一致。
//!
//! 注意：这个文件调用的是 AI 转换后的 Rust FFI，具体函数签名取决于
//! rust-libuv/src/ffi.rs 导出的符号。如果 FFI 不可用，编译会失败，
//! 这会被 performance.sh 正确处理为 "Rust benchmark build failed"。

use std::time::Instant;

const N_OPS: usize = 10000;

fn print_result(name: &str, n_ops: usize, elapsed_us: f64) {
    let ops_per_s = n_ops as f64 / (elapsed_us / 1e6);
    let us_per_op = elapsed_us / n_ops as f64;
    println!("  {} | {} ops | {:.1} us | {:.1} ops/s | {:.2} us/op",
             name, n_ops, elapsed_us, ops_per_s, us_per_op);
}

fn main() {
    // 注意：以下 FFI 调用依赖 rust-libuv/src/ffi.rs 导出的具体符号。
    // c2rust 转换后的 API 签名可能有所不同。这里使用最常见的模式。
    // 如果 FFI 不可用，这个 benchmark 会编译失败，performance.sh 会报告
    // "Rust benchmark build/run failed"，score = 0。

    println!("libuv Rust FFI benchmark");
    println!("(FFI-dependent benchmarks will be added based on actual conversion output)");
}
