#!/usr/bin/env python3
"""
aggregate-score.py — 聚合编译、测试、功能等价、性能四个维度的评测结果，生成最终报告。

用法: python3 scripts/aggregate-score.py <compile.json> <test.json> <equiv.json> <perf.json> [output.md]

输出: 评测报告 (Markdown 格式) 写入 output.md 或 stdout。
"""

import json
import sys
from pathlib import Path


def load_json(path: str) -> dict:
    try:
        with open(path) as f:
            content = f.read().strip()
            if not content:
                return {"error": "empty file"}
            return json.loads(content)
    except (json.JSONDecodeError, FileNotFoundError) as e:
        return {"error": str(e)}


def score_compile(result: dict) -> float:
    """编译评分: 通过=1.0, 失败=0.0"""
    return 1.0 if result.get("pass", False) else 0.0


def score_test(result: dict) -> float:
    """测试评分: 通过率 = passed / total, 全部通过=1.0
    当 total=0 时：
    - 如果 pass=true（编译成功但无测试），返回 0.5（基础分）
    - 如果 pass=false（测试失败），返回 0.0
    """
    total = result.get("total", 0)
    if total == 0:
        # 无测试用例：编译成功给基础分，否则 0
        return 0.5 if result.get("pass", False) else 0.0
    passed = result.get("passed", 0)
    return passed / total


def score_equivalence(result: dict) -> float:
    """功能等价评分: 通过率 = passed / total, 无 FFI 时返回 0"""
    if not result.get("ffi_present", False):
        return 0.0
    total = result.get("total", 0)
    if total == 0:
        return 0.0
    passed = result.get("passed", 0)
    return passed / total


def compute_perf_ratios(perf: dict) -> dict:
    """从 c_metrics 和 rust_metrics 计算每个指标的比率。返回 {"ratios": {...}, "avg_ratio": float}"""
    c_metrics = perf.get("c_metrics", {})
    rust_metrics = perf.get("rust_metrics", {})

    if not c_metrics or not rust_metrics:
        return {"ratios": {}, "avg_ratio": 0.0}

    ratios = {}
    for key in c_metrics:
        c_val = c_metrics.get(key, 0)
        r_val = rust_metrics.get(key, 0)
        if c_val > 0 and r_val > 0:
            ratios[key] = round(r_val / c_val, 2)

    avg = sum(ratios.values()) / len(ratios) if ratios else 0.0
    return {"ratios": ratios, "avg_ratio": round(avg, 2)}


def score_performance(result: dict) -> float:
    """性能评分: 基于平均比率。ratio <= 1.0 = 满分, ratio >= max_ratio = 0分"""
    # Handle error case
    if "error" in result and "c_metrics" not in result:
        return 0.0

    # Try to get avg_ratio directly, or compute from metrics
    avg_ratio = result.get("avg_ratio", 0)
    if avg_ratio <= 0:
        perf_data = compute_perf_ratios(result)
        avg_ratio = perf_data["avg_ratio"]

    max_ratio = result.get("max_ratio_allowed", 1.5)

    if avg_ratio <= 0:
        return 0.0
    if avg_ratio <= 1.0:
        return 1.0
    if avg_ratio >= max_ratio:
        return 0.0
    # 线性插值: ratio=1.0 → score=1.0, ratio=max_ratio → score=0.0
    return max(0.0, (max_ratio - avg_ratio) / (max_ratio - 1.0))


def grade(score: float) -> str:
    if score >= 0.9:
        return "A"
    elif score >= 0.8:
        return "B"
    elif score >= 0.7:
        return "C"
    elif score >= 0.6:
        return "D"
    else:
        return "F"


def generate_report(
    compile_result: dict,
    test_result: dict,
    equiv_result: dict,
    perf_result: dict,
    weights: dict,
) -> str:
    compile_w = weights.get("compile", 0.40)
    test_w = weights.get("test", 0.20)
    equiv_w = weights.get("equivalence", 0.25)
    perf_w = weights.get("performance", 0.15)

    s_compile = score_compile(compile_result)
    s_test = score_test(test_result)
    s_equiv = score_equivalence(equiv_result)
    s_perf = score_performance(perf_result)

    total = s_compile * compile_w + s_test * test_w + s_equiv * equiv_w + s_perf * perf_w

    # Compute perf ratios for report
    perf_data = compute_perf_ratios(perf_result)
    ratios = perf_data["ratios"]
    avg_ratio = perf_data["avg_ratio"]
    max_r = perf_result.get("max_ratio_allowed", 1.5)

    lines = []
    lines.append("# FlashDB C→Rust 迁移评测报告\n")
    lines.append(f"## 总分: {total:.1%} (等级: {grade(total)})\n")
    lines.append(f"| 维度 | 权重 | 得分 | 状态 |")
    lines.append(f"|------|------|------|------|")
    lines.append(f"| 编译 | {compile_w:.0%} | {s_compile:.1%} | {'✅ 通过' if compile_result.get('pass') else '❌ 失败'} |")
    lines.append(f"| 测试 | {test_w:.0%} | {s_test:.1%} | {'✅ 通过' if test_result.get('pass') else '❌ 失败'} |")
    # 功能等价状态: 根据实际得分显示，同时显示 API 覆盖率
    equiv_cov = equiv_result.get("api_coverage", {})
    if equiv_cov and equiv_cov.get("expected", 0) > 0:
        cov_pct = equiv_cov.get("implemented", 0) / equiv_cov["expected"]
        cov_label = f'{cov_pct:.0%} API'
    else:
        cov_label = '无 API'

    # 状态基于实际得分
    if equiv_result.get("link_error") or equiv_result.get("rust_build_error"):
        equiv_status = f'❌ 构建失败 ({cov_label})'
    elif s_equiv > 0.9:
        equiv_status = f'✅ 等价 ({cov_label})'
    elif s_equiv > 0:
        equiv_status = f'⚠️ 部分 ({cov_label})'
    else:
        equiv_status = f'❌ 失败 ({cov_label})'
    lines.append(f"| 功能等价 | {equiv_w:.0%} | {s_equiv:.1%} | {equiv_status} |")
    lines.append(f"| 性能 | {perf_w:.0%} | {s_perf:.1%} | {'✅ 达标' if s_perf > 0.5 else '❌ 不达标'} |")
    lines.append("")

    # 编译详情
    lines.append("## 编译详情\n")
    if "error" in compile_result:
        lines.append(f"- ⚠️ 错误: {compile_result['error']}")
    else:
        lines.append(f"- 编译错误数: {compile_result.get('errors', 'N/A')}")
        lines.append(f"- 编译警告数: {compile_result.get('warnings', 'N/A')}")
    lines.append("")

    # Unsafe 函数比例
    total_fn = compile_result.get("total_fn", 0)
    unsafe_fn = compile_result.get("unsafe_fn", 0)
    if total_fn > 0:
        unsafe_pct = unsafe_fn / total_fn * 100
        lines.append("## Unsafe 函数分析\n")
        lines.append(f"- 总函数数: {total_fn}")
        lines.append(f"- 含 unsafe 操作的函数数: {unsafe_fn} ({unsafe_pct:.1f}%)")
        lines.append(f"  - unsafe 操作包括: `null_mut`、`null::<T>`、`ptr::null`、`&raw mut`")
        lines.append("")

    # 测试详情
    lines.append("## 测试详情\n")
    if "error" in test_result:
        lines.append(f"- ⚠️ 错误: {test_result['error']}")
    else:
        total_tests = test_result.get('total', 0)
        if total_tests == 0:
            if test_result.get('pass', False):
                lines.append("- ⚠️ 无测试用例（c2rust 不自动生成单元测试，基础分 0.5）")
            else:
                lines.append("- ❌ 测试执行失败")
        else:
            lines.append(f"- 通过: {test_result.get('passed', 0)}")
            lines.append(f"- 失败: {test_result.get('failed', 0)}")
            lines.append(f"- 忽略: {test_result.get('ignored', 0)}")
            lines.append(f"- 总计: {total_tests}")
    lines.append("")

    # 功能等价详情
    lines.append("## 功能等价详情\n")
    if not equiv_result.get("ffi_present", False):
        lines.append("- ⚠️ 未检测到 FFI 兼容层 (ffi.rs)")
        lines.append("- Rust 代码需在 `src/ffi.rs` 中暴露 C 兼容函数")
    else:
        # API 覆盖率
        cov = equiv_result.get("api_coverage", {})
        if cov:
            exp = cov.get("expected", 0)
            imp = cov.get("implemented", 0)
            pct = (imp / exp * 100) if exp > 0 else 0
            lines.append(f"### API 覆盖率: {imp}/{exp} ({pct:.0f}%)\n")
            lines.append("| 类别 | 期望 | 实现 | 覆盖率 |")
            lines.append("|------|------|------|--------|")
            for cat, label in [("crc32", "CRC32"), ("kvdb", "KVDB"), ("tsdb", "TSDB")]:
                c = cov.get(cat, {})
                e = c.get("expected", 0)
                i = c.get("implemented", 0)
                p = (i / e * 100) if e > 0 else 0
                lines.append(f"| {label} | {e} | {i} | {p:.0f}% |")
            lines.append("")

        # Rust 构建错误
        if "rust_build_error" in equiv_result:
            lines.append(f"- ❌ Rust 构建失败: {equiv_result['rust_build_error'][:100]}")
        elif "link_error" in equiv_result:
            lines.append(f"- ❌ 链接失败: {equiv_result['link_error'][:100]}")
        elif "error" in equiv_result:
            lines.append(f"- ⚠️ 错误: {equiv_result['error']}")
        else:
            # 测试结果
            lines.append(f"### 对比测试结果\n")
            lines.append(f"- 通过: {equiv_result.get('passed', 0)}")
            lines.append(f"- 失败: {equiv_result.get('failed', 0)}")
            lines.append(f"- 总计: {equiv_result.get('total', 0)}")
            lines.append("")
            details = equiv_result.get("details", {})
            if details:
                lines.append("| 类别 | 通过 | 失败 |")
                lines.append("|------|------|------|")
                for cat, label in [("crc32", "CRC32"), ("kvdb", "KVDB"), ("tsdb", "TSDB")]:
                    d = details.get(cat, {})
                    lines.append(f"| {label} | {d.get('passed', 0)} | {d.get('failed', 0)} |")
    lines.append("")

    # 性能详情
    lines.append("## 性能详情\n")
    if "error" in perf_result and "c_metrics" not in perf_result:
        lines.append(f"- ⚠️ 错误: {perf_result['error']}")
    elif not ratios:
        lines.append("- ⚠️ 无可用的性能数据")
        note = perf_result.get("note", "")
        if note:
            lines.append(f"- 原因: {note}")
        c_bench_diag = perf_result.get("c_bench_diag", "")
        if c_bench_diag:
            lines.append(f"- C benchmark 诊断: {c_bench_diag}")
    else:
        lines.append(f"- 平均性能比: {avg_ratio}x (基准: ≤{max_r}x)")
        lines.append("")
        lines.append("| 指标 | C 基线 (ns) | Rust (ns) | 比率 | 状态 |")
        lines.append("|------|-------------|-----------|------|------|")

        metric_labels = {
            "kvdb_set_string": "KVDB Set (String)",
            "kvdb_set_blob": "KVDB Set (Blob)",
            "kvdb_get_string": "KVDB Get (String)",
            "kvdb_get_blob": "KVDB Get (Blob)",
            "kvdb_update": "KVDB Update",
            "kvdb_iterate": "KVDB Iterate",
            "kvdb_delete": "KVDB Delete",
            "tsdb_append": "TSDB Append",
            "tsdb_iterate": "TSDB Iterate",
            "tsdb_iter_by_time": "TSDB Iter by Time",
            "tsdb_query_count": "TSDB Query Count",
        }

        c_metrics = perf_result.get("c_metrics", {})
        rust_metrics = perf_result.get("rust_metrics", {})

        for key, label in metric_labels.items():
            c_val = c_metrics.get(key, 0)
            r_val = rust_metrics.get(key, 0)
            ratio = ratios.get(key, 0)
            status = "✅" if 0 < ratio <= max_r else ("⚠️" if ratio == 0 else "❌")
            lines.append(f"| {label} | {c_val} | {r_val} | {ratio}x | {status} |")

    lines.append("")
    lines.append("---")
    lines.append("*由 c_cpp_to_rust_verify 自动生成*")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 5:
        print("用法: python3 aggregate-score.py <compile.json> <test.json> <equiv.json> <perf.json> [output.md]", file=sys.stderr)
        sys.exit(1)

    compile_file = sys.argv[1]
    test_file = sys.argv[2]
    equiv_file = sys.argv[3]
    perf_file = sys.argv[4]
    output_file = sys.argv[5] if len(sys.argv) > 5 else None

    # 加载评测配置
    config_path = Path(compile_file).parent.parent / "eval-config.json"
    weights = {"compile": 0.40, "test": 0.20, "equivalence": 0.25, "performance": 0.15}
    if config_path.exists():
        try:
            with open(config_path) as f:
                cfg = json.load(f)
                weights = cfg.get("weights", weights)
        except Exception:
            pass

    compile_result = load_json(compile_file)
    test_result = load_json(test_file)
    equiv_result = load_json(equiv_file)
    perf_result = load_json(perf_file)

    report = generate_report(compile_result, test_result, equiv_result, perf_result, weights)

    if output_file:
        with open(output_file, "w") as f:
            f.write(report)
        print(f"Report written to {output_file}", file=sys.stderr)
    else:
        print(report)


if __name__ == "__main__":
    main()
