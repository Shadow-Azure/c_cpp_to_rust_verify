#!/usr/bin/env python3
"""
analyze-session.py — 分析 OpenCode session 和 compile trajectory，生成转换过程报告。

OBSERVABILITY ONLY — never affects scoring or pass/fail.

用法:
    python3 scripts/analyze-session.py <session.json> <trajectory.jsonl>

输出: Markdown 格式报告追加到 stdout，可直接追加到 eval-report.md。
"""

import json
import sys
from datetime import datetime, timezone
from typing import Optional


def load_trajectory(path: str) -> list:
    """加载 compile-trajectory.jsonl"""
    entries = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        entries.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
    except (FileNotFoundError, OSError):
        pass
    return entries


def load_session(path: str) -> dict:
    """加载 opencode session JSON"""
    try:
        with open(path) as f:
            content = f.read()

            # 跳过开头的非 JSON 行（如 "Exporting session: ..."）
            lines = content.split('\n')
            json_start = 0
            for i, line in enumerate(lines):
                stripped = line.strip()
                if stripped.startswith('{'):
                    json_start = i
                    break

            # 重新组合 JSON 内容
            json_content = '\n'.join(lines[json_start:])
            return json.loads(json_content)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def format_duration(ms: int) -> str:
    """毫秒转为人类可读的时间格式"""
    if ms < 0:
        return "—"
    seconds = ms / 1000
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes = seconds / 60
    if minutes < 60:
        return f"{minutes:.1f}min"
    hours = minutes / 60
    return f"{hours:.1f}h"


def format_timestamp(ts_ms: int) -> str:
    """毫秒时间戳转为 HH:MM:SS 格式"""
    try:
        dt = datetime.fromtimestamp(ts_ms / 1000, tz=timezone.utc)
        return dt.strftime("%H:%M:%S")
    except (ValueError, OSError):
        return "—"


def analyze_trajectory(entries: list) -> dict:
    """分析 compile trajectory"""
    if not entries:
        return {"has_data": False}

    cargo_checks = [e for e in entries if e.get("phase") == "cargo-check"]
    cargo_builds = [e for e in entries if e.get("phase") == "cargo-build"]

    # 错误变化趋势
    error_trend = []
    for e in cargo_checks:
        errors = e.get("errors", 0)
        full_errors = e.get("full_error_count")
        # 优先使用 full_error_count（更准确）
        actual_errors = full_errors if full_errors is not None else errors
        error_trend.append({
            "ts": e.get("ts", ""),
            "errors": actual_errors,
            "cmd": e.get("cmd", "")[:60],
        })

    # 找到首次和最终错误数
    first_errors = error_trend[0]["errors"] if error_trend else 0
    last_errors = error_trend[-1]["errors"] if error_trend else 0

    # 统计通过的编译（exit_ok 为 True 或 errors 为 0）
    passed_checks = [e for e in cargo_checks if e.get("exit_ok") is True or e.get("errors", 0) == 0]
    passed_builds = [e for e in cargo_builds if e.get("exit_ok") is True or e.get("errors", 0) == 0]

    return {
        "has_data": True,
        "total_checks": len(cargo_checks),
        "total_builds": len(cargo_builds),
        "passed_checks": len(passed_checks),
        "passed_builds": len(passed_builds),
        "first_errors": first_errors,
        "last_errors": last_errors,
        "error_trend": error_trend,
    }


def analyze_session(session: dict) -> dict:
    """分析 opencode session"""
    if not session:
        return {"has_data": False}

    info = session.get("info", {})
    messages = session.get("messages", [])

    # 总用时
    time_info = info.get("time", {})
    created = time_info.get("created", 0)
    updated = time_info.get("updated", 0)
    total_duration_ms = updated - created if created and updated else 0

    # 成本和 token
    cost = info.get("cost", 0)
    tokens = info.get("tokens", {})

    # 分析每条消息的用时
    message_durations = []
    for msg in messages:
        msg_info = msg.get("info", {})
        msg_time = msg_info.get("time", {})
        msg_created = msg_time.get("created", 0)
        msg_completed = msg_time.get("completed", 0)

        if msg_created and msg_completed:
            duration = msg_completed - msg_created
            role = msg_info.get("role", "unknown")

            # 提取内容摘要
            parts = msg.get("parts", [])
            summary = ""
            for part in parts:
                if part.get("type") == "text":
                    text = part.get("text", "")
                    summary = text[:80].replace("\n", " ")
                    break
                elif part.get("type") == "reasoning":
                    summary = "[reasoning]"
                    break

            message_durations.append({
                "role": role,
                "duration_ms": duration,
                "summary": summary,
            })

    # 分析 tool 调用
    tool_calls = []
    for msg in messages:
        parts = msg.get("parts", [])
        for part in parts:
            if part.get("type") == "tool":
                tool_name = part.get("tool", "unknown")
                state = part.get("state", {})
                status = state.get("status", "unknown")

                # 提取 tool 输入摘要
                input_data = state.get("input", {})
                input_summary = ""
                if tool_name == "bash":
                    cmd = input_data.get("command", "")
                    input_summary = cmd[:60].replace("\n", " ")
                elif tool_name == "skill":
                    input_summary = input_data.get("name", "")
                else:
                    input_summary = str(input_data)[:60]

                tool_calls.append({
                    "tool": tool_name,
                    "status": status,
                    "input": input_summary,
                })

    return {
        "has_data": True,
        "total_duration_ms": total_duration_ms,
        "cost": cost,
        "tokens": tokens,
        "message_count": len(messages),
        "message_durations": message_durations,
        "tool_calls": tool_calls,
    }


def generate_report(session_data: dict, trajectory_data: dict) -> str:
    """生成 Markdown 报告"""
    lines = []
    lines.append("")
    lines.append("## 转换过程分析")
    lines.append("")

    # Session 分析
    if session_data.get("has_data"):
        lines.append("### OpenCode Session 概览")
        lines.append("")
        lines.append(f"| 指标 | 值 |")
        lines.append(f"|------|-----|")
        lines.append(f"| 总用时 | {format_duration(session_data['total_duration_ms'])} |")
        lines.append(f"| 消息数 | {session_data['message_count']} |")
        lines.append(f"| 成本 | ${session_data['cost']:.4f} |")

        tokens = session_data.get("tokens", {})
        if tokens:
            lines.append(f"| 输入 tokens | {tokens.get('input', 0):,} |")
            lines.append(f"| 输出 tokens | {tokens.get('output', 0):,} |")
            lines.append(f"| 推理 tokens | {tokens.get('reasoning', 0):,} |")
            cache = tokens.get("cache", {})
            if cache:
                lines.append(f"| 缓存读取 | {cache.get('read', 0):,} |")
        lines.append("")

        # Tool 调用统计
        tool_calls = session_data.get("tool_calls", [])
        if tool_calls:
            # 统计每种 tool 的调用次数
            tool_stats = {}
            for tc in tool_calls:
                tool = tc["tool"]
                if tool not in tool_stats:
                    tool_stats[tool] = {"total": 0, "success": 0}
                tool_stats[tool]["total"] += 1
                if tc["status"] == "completed":
                    tool_stats[tool]["success"] += 1

            lines.append("### Tool 调用统计")
            lines.append("")
            lines.append("| Tool | 调用次数 | 成功 |")
            lines.append("|------|---------|------|")
            for tool, stats in sorted(tool_stats.items()):
                lines.append(f"| {tool} | {stats['total']} | {stats['success']} |")
            lines.append("")

        # 耗时最长的 5 条消息
        durations = session_data.get("message_durations", [])
        if durations:
            # 按耗时排序
            sorted_durations = sorted(durations, key=lambda x: x["duration_ms"], reverse=True)
            top5 = sorted_durations[:5]

            lines.append("### 耗时最长的步骤 (Top 5)")
            lines.append("")
            lines.append("| 角色 | 耗时 | 摘要 |")
            lines.append("|------|------|------|")
            for d in top5:
                lines.append(f"| {d['role']} | {format_duration(d['duration_ms'])} | {d['summary'][:50]}... |")
            lines.append("")
    else:
        lines.append("### OpenCode Session 概览")
        lines.append("")
        lines.append("⚠️ 无 session 数据")
        lines.append("")

    # Trajectory 分析
    if trajectory_data.get("has_data"):
        lines.append("### 编译轨迹 (Compile Trajectory)")
        lines.append("")
        lines.append(f"| 指标 | 值 |")
        lines.append(f"|------|-----|")
        lines.append(f"| cargo check 次数 | {trajectory_data['total_checks']} |")
        lines.append(f"| cargo build 次数 | {trajectory_data['total_builds']} |")
        lines.append(f"| 编译通过次数 | {trajectory_data['passed_checks']} |")
        lines.append(f"| 首次错误数 | {trajectory_data['first_errors']} |")
        lines.append(f"| 最终错误数 | {trajectory_data['last_errors']} |")
        lines.append("")

        # 错误变化趋势
        error_trend = trajectory_data.get("error_trend", [])
        if error_trend:
            lines.append("### 错误数变化趋势")
            lines.append("")
            lines.append("```")
            lines.append("错误数")
            lines.append("  |")

            # 找到最大错误数用于缩放
            max_errors = max(e["errors"] for e in error_trend) if error_trend else 1
            if max_errors == 0:
                max_errors = 1

            # 简单的 ASCII 图表
            chart_height = 10
            for level in range(chart_height, 0, -1):
                threshold = max_errors * level / chart_height
                line = f"{threshold:4.0f} |"
                for e in error_trend:
                    if e["errors"] >= threshold:
                        line += "█"
                    else:
                        line += " "
                lines.append(line)

            lines.append("    +" + "─" * len(error_trend))
            lines.append("     " + "".join(str(i % 10) for i in range(len(error_trend))))
            lines.append("     " + "↑ cargo check 调用序号")
            lines.append("```")
            lines.append("")

            # 详细表格
            lines.append("#### 详细记录")
            lines.append("")
            lines.append("| 序号 | 时间 | 错误数 | 命令 |")
            lines.append("|------|------|--------|------|")
            for i, e in enumerate(error_trend):
                ts = e["ts"][:19] if e["ts"] else "—"
                lines.append(f"| {i+1} | {ts} | {e['errors']} | `{e['cmd'][:40]}...` |")
            lines.append("")
    else:
        lines.append("### 编译轨迹 (Compile Trajectory)")
        lines.append("")
        lines.append("⚠️ 无 trajectory 数据")
        lines.append("")

    # 问题分析
    lines.append("### 问题分析")
    lines.append("")

    issues = []

    # 检查是否有过多的 cargo check 调用
    if trajectory_data.get("has_data"):
        if trajectory_data["total_checks"] > 10:
            issues.append(f"- ⚠️ cargo check 调用次数较多 ({trajectory_data['total_checks']} 次)，可能存在编译问题反复")

        if trajectory_data["last_errors"] > 0:
            issues.append(f"- ❌ 最终编译仍有 {trajectory_data['last_errors']} 个错误")

    # 检查 session 耗时
    if session_data.get("has_data"):
        total_min = session_data["total_duration_ms"] / 60000
        if total_min > 30:
            issues.append(f"- ⚠️ 转换耗时较长 ({total_min:.1f} 分钟)")

        # 检查是否有失败的 tool 调用
        failed_tools = [tc for tc in session_data.get("tool_calls", []) if tc["status"] != "completed"]
        if failed_tools:
            issues.append(f"- ⚠️ 有 {len(failed_tools)} 个 tool 调用失败")

    if not issues:
        issues.append("- ✅ 未发现明显问题")

    lines.extend(issues)
    lines.append("")
    lines.append("---")
    lines.append("")

    return "\n".join(lines)


def main():
    if len(sys.argv) < 3:
        print("用法: python3 analyze-session.py <session.json> <trajectory.jsonl>", file=sys.stderr)
        sys.exit(1)

    session_path = sys.argv[1]
    trajectory_path = sys.argv[2]

    session = load_session(session_path)
    trajectory = load_trajectory(trajectory_path)

    session_data = analyze_session(session)
    trajectory_data = analyze_trajectory(trajectory)

    report = generate_report(session_data, trajectory_data)
    print(report, end="")


if __name__ == "__main__":
    main()
