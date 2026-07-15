#!/usr/bin/env python3
"""
analyze-session.py — 分析 OpenCode session（含 task 派生的 subagent）和 compile
trajectory，生成转换过程报告。

OBSERVABILITY ONLY — never affects scoring or pass/fail.

用法:
    # 目录模式（推荐）：目录里含 manifest.json + session-*.json
    python3 scripts/analyze-session.py <sessions-dir> <trajectory.jsonl>

    # 单文件模式（向后兼容）：只分析一个 session 文件
    python3 scripts/analyze-session.py <session.json> <trajectory.jsonl>

输出: Markdown 格式报告追加到 stdout，可直接追加到 eval-report.md。
"""

import json
import os
import sys
from datetime import datetime, timezone


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
    """加载 opencode session JSON（跳过 'Exporting session:' 前缀行）"""
    try:
        with open(path) as f:
            content = f.read()
        idx = content.find('{')
        if idx < 0:
            return {}
        return json.loads(content[idx:])
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def format_duration(ms):
    """毫秒转人类可读；None/负值 → —"""
    if ms is None or ms < 0:
        return "—"
    seconds = ms / 1000
    if seconds < 60:
        return f"{seconds:.1f}s"
    minutes = seconds / 60
    if minutes < 60:
        return f"{minutes:.1f}min"
    hours = minutes / 60
    return f"{hours:.1f}h"


def analyze_trajectory(entries: list) -> dict:
    """分析 compile trajectory"""
    if not entries:
        return {"has_data": False}

    cargo_checks = [e for e in entries if e.get("phase") == "cargo-check"]
    cargo_builds = [e for e in entries if e.get("phase") == "cargo-build"]

    error_trend = []
    for e in cargo_checks:
        errors = e.get("errors", 0)
        full_errors = e.get("full_error_count")
        actual_errors = full_errors if full_errors is not None else errors
        error_trend.append({
            "ts": e.get("ts", ""),
            "errors": actual_errors,
            "cmd": e.get("cmd", "")[:60],
        })

    first_errors = error_trend[0]["errors"] if error_trend else 0
    last_errors = error_trend[-1]["errors"] if error_trend else 0

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


def summarize_session(session: dict) -> dict:
    """单个 session 的成本/耗时/消息/tool 统计。"""
    if not session:
        return {"has_data": False}

    info = session.get("info", {}) or {}
    time_info = info.get("time", {}) or {}
    created = time_info.get("created", 0)
    updated = time_info.get("updated", 0)
    duration_ms = (updated - created) if created and updated else 0
    messages = session.get("messages", [])

    # 消息耗时 + 摘要
    message_durations = []
    for msg in messages:
        msg_info = msg.get("info", {}) or {}
        msg_time = msg_info.get("time", {}) or {}
        mc = msg_time.get("created", 0)
        md = msg_time.get("completed", 0)
        if mc and md:
            role = msg_info.get("role", "unknown")
            summary = ""
            for part in msg.get("parts", []):
                if part.get("type") == "text":
                    summary = (part.get("text", "") or "")[:80].replace("\n", " ")
                    break
                elif part.get("type") == "reasoning":
                    summary = "[reasoning]"
                    break
            message_durations.append({"role": role, "duration_ms": md - mc, "summary": summary})

    # tool 调用
    tool_calls = []
    for msg in messages:
        for part in msg.get("parts", []):
            if part.get("type") == "tool":
                tool_name = part.get("tool", "unknown")
                state = part.get("state", {}) or {}
                status = state.get("status", "unknown")
                input_data = state.get("input", {}) or {}
                if tool_name == "bash":
                    input_summary = (input_data.get("command", "") or "")[:60].replace("\n", " ")
                elif tool_name == "skill":
                    input_summary = input_data.get("name", "")
                elif tool_name == "task":
                    input_summary = (input_data.get("description", "") or input_data.get("subagent_type", ""))[:60]
                else:
                    input_summary = str(input_data)[:60]
                tool_calls.append({"tool": tool_name, "status": status, "input": input_summary})

    return {
        "has_data": True,
        "id": info.get("id", ""),
        "agent": info.get("agent", ""),
        "title": info.get("title", ""),
        "duration_ms": duration_ms,
        "cost": info.get("cost", 0) or 0,
        "tokens": info.get("tokens", {}) or {},
        "message_count": len(messages),
        "message_durations": message_durations,
        "tool_calls": tool_calls,
    }


def add_tokens(dst: dict, src: dict):
    """累加 token 字典（input/output/reasoning + cache 子项）。"""
    for k in ("input", "output", "reasoning"):
        dst[k] = dst.get(k, 0) + (src.get(k, 0) or 0)
    dcache = dst.setdefault("cache", {})
    scache = src.get("cache", {}) or {}
    for k in ("read", "write"):
        dcache[k] = dcache.get(k, 0) + (scache.get(k, 0) or 0)


def load_sessions(arg: str):
    """
    从参数加载 session 集合。返回 manifest 列表（每条含 role/subagent_type/...）和
    {id: session_dict}。支持目录（含 manifest.json）和单文件。
    """
    if os.path.isdir(arg):
        manifest_path = os.path.join(arg, "manifest.json")
        if os.path.exists(manifest_path):
            try:
                with open(manifest_path) as f:
                    manifest = json.load(f)
            except (json.JSONDecodeError, OSError):
                manifest = []
        else:
            # 无 manifest：glob 推断，全部当 main
            manifest = []
            for fn in sorted(os.listdir(arg)):
                if fn.startswith("session-") and fn.endswith(".json"):
                    manifest.append({"id": fn[8:-5], "file": fn, "role": "main",
                                     "subagent_type": None, "description": "", "task_status": None})
        sessions = {}
        for entry in manifest:
            sessions[entry["id"]] = load_session(os.path.join(arg, entry.get("file", "")))
        return manifest, sessions

    # 单文件
    session = load_session(arg)
    sid = (session.get("info", {}) or {}).get("id", "main")
    return [{"id": sid, "file": os.path.basename(arg), "role": "main",
             "subagent_type": None, "description": "", "task_status": None}], {sid: session}


def generate_report(manifest, sessions, trajectory_data) -> str:
    """生成 Markdown 报告（含 subagent 聚合）。"""
    lines = ["", "## 转换过程分析", ""]

    # 每个 session 的摘要
    summaries = {sid: summarize_session(s) for sid, s in sessions.items()}
    mains = [e for e in manifest if e.get("role") == "main"]
    subs = [e for e in manifest if e.get("role") == "subagent"]

    any_data = any(s.get("has_data") for s in summaries.values())

    if any_data:
        # 聚合
        main_cost = sum(summaries[e["id"]].get("cost", 0) for e in mains if summaries[e["id"]].get("has_data"))
        sub_cost = sum(summaries[e["id"]].get("cost", 0) for e in subs if summaries[e["id"]].get("has_data"))
        main_dur = max((summaries[e["id"]].get("duration_ms", 0) for e in mains if summaries[e["id"]].get("has_data")), default=0)
        sub_dur = sum(summaries[e["id"]].get("duration_ms", 0) for e in subs if summaries[e["id"]].get("has_data"))
        main_msgs = sum(summaries[e["id"]].get("message_count", 0) for e in mains if summaries[e["id"]].get("has_data"))
        sub_msgs = sum(summaries[e["id"]].get("message_count", 0) for e in subs if summaries[e["id"]].get("has_data"))

        main_tok, sub_tok, total_tok = {}, {}, {}
        for e in mains:
            if summaries[e["id"]].get("has_data"):
                add_tokens(main_tok, summaries[e["id"]].get("tokens", {}))
        for e in subs:
            if summaries[e["id"]].get("has_data"):
                add_tokens(sub_tok, summaries[e["id"]].get("tokens", {}))
        add_tokens(total_tok, main_tok)
        add_tokens(total_tok, sub_tok)

        has_subs = len(subs) > 0

        lines.append("### OpenCode Session 概览" + ("（含 subagent）" if has_subs else ""))
        lines.append("")
        lines.append("| 指标 | 主 session | subagent(%d) | 合计 |" % len(subs))
        lines.append("|------|-----------|--------------|------|")
        lines.append(f"| 总用时 | {format_duration(main_dur)} | {format_duration(sub_dur)} | {format_duration(main_dur)} |")
        lines.append(f"| 消息数 | {main_msgs} | {sub_msgs} | {main_msgs + sub_msgs} |")
        lines.append(f"| 成本 | ${main_cost:.4f} | ${sub_cost:.4f} | ${main_cost + sub_cost:.4f} |")
        lines.append(f"| 输入 tokens | {main_tok.get('input',0):,} | {sub_tok.get('input',0):,} | {total_tok.get('input',0):,} |")
        lines.append(f"| 输出 tokens | {main_tok.get('output',0):,} | {sub_tok.get('output',0):,} | {total_tok.get('output',0):,} |")
        lines.append(f"| 推理 tokens | {main_tok.get('reasoning',0):,} | {sub_tok.get('reasoning',0):,} | {total_tok.get('reasoning',0):,} |")
        if total_tok.get("cache"):
            lines.append(f"| 缓存读取 | {main_tok.get('cache',{}).get('read',0):,} | {sub_tok.get('cache',{}).get('read',0):,} | {total_tok.get('cache',{}).get('read',0):,} |")
        lines.append("")
        if has_subs:
            lines.append("> 注：主 session 的「总用时」为实际墙钟时间；subagent 在其内部执行，"
                         "「subagent 累计」不额外叠加到墙钟时间。成本/token 为各 session 独立计量后求和"
                         "（修正了此前仅统计主 session 的低估）。")
            lines.append("")

        # Subagent 明细
        if has_subs:
            lines.append("### Subagent 明细")
            lines.append("")
            lines.append("| # | 类型 | 描述 | 成本 | 耗时 | 消息 | 状态 |")
            lines.append("|---|------|------|------|------|------|------|")
            for i, e in enumerate(subs, 1):
                s = summaries[e["id"]]
                status_raw = e.get("task_status") or ""
                icon = "✅" if status_raw == "completed" else ("❌" if status_raw in ("failed", "error") else "—")
                cost = s.get("cost", 0) if s.get("has_data") else 0
                dur = s.get("duration_ms", 0) if s.get("has_data") else 0
                msgs = s.get("message_count", 0) if s.get("has_data") else 0
                exported = "—" if not s.get("has_data") else ""
                desc = (e.get("description") or "")[:40]
                lines.append(f"| {i} | {e.get('subagent_type') or exported or '?'} | {desc} | ${cost:.4f} | {format_duration(dur)} | {msgs} | {icon} |")
            lines.append("")

        # 合并 tool 调用统计（所有 session）
        all_tools = []
        for s in summaries.values():
            all_tools.extend(s.get("tool_calls", []))
        if all_tools:
            tool_stats = {}
            for tc in all_tools:
                tool = tc["tool"]
                st = tool_stats.setdefault(tool, {"total": 0, "success": 0})
                st["total"] += 1
                if tc["status"] == "completed":
                    st["success"] += 1
            lines.append("### Tool 调用统计（合计）")
            lines.append("")
            lines.append("| Tool | 调用次数 | 成功 |")
            lines.append("|------|---------|------|")
            for tool, stats in sorted(tool_stats.items()):
                lines.append(f"| {tool} | {stats['total']} | {stats['success']} |")
            lines.append("")

        # 合并耗时最长的步骤（所有 session）
        all_durations = []
        for s in summaries.values():
            all_durations.extend(s.get("message_durations", []))
        if all_durations:
            top5 = sorted(all_durations, key=lambda x: x["duration_ms"], reverse=True)[:5]
            lines.append("### 耗时最长的步骤 (Top 5，含 subagent)")
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
        lines.append("| 指标 | 值 |")
        lines.append("|------|-----|")
        lines.append(f"| cargo check 次数 | {trajectory_data['total_checks']} |")
        lines.append(f"| cargo build 次数 | {trajectory_data['total_builds']} |")
        lines.append(f"| 编译通过次数 | {trajectory_data['passed_checks']} |")
        lines.append(f"| 首次错误数 | {trajectory_data['first_errors']} |")
        lines.append(f"| 最终错误数 | {trajectory_data['last_errors']} |")
        lines.append("")

        error_trend = trajectory_data.get("error_trend", [])
        if error_trend:
            lines.append("### 错误数变化趋势")
            lines.append("")
            lines.append("```")
            lines.append("错误数")
            lines.append("  |")
            max_errors = max(e["errors"] for e in error_trend) if error_trend else 1
            if max_errors == 0:
                max_errors = 1
            chart_height = 10
            for level in range(chart_height, 0, -1):
                threshold = max_errors * level / chart_height
                line = f"{threshold:4.0f} |"
                for e in error_trend:
                    line += "█" if e["errors"] >= threshold else " "
                lines.append(line)
            lines.append("    +" + "─" * len(error_trend))
            lines.append("     " + "".join(str(i % 10) for i in range(len(error_trend))))
            lines.append("     " + "↑ cargo check 调用序号")
            lines.append("```")
            lines.append("")
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
    if trajectory_data.get("has_data"):
        if trajectory_data["total_checks"] > 10:
            issues.append(f"- ⚠️ cargo check 调用次数较多 ({trajectory_data['total_checks']} 次)，可能存在编译问题反复")
        if trajectory_data["last_errors"] > 0:
            issues.append(f"- ❌ 最终编译仍有 {trajectory_data['last_errors']} 个错误")
    if any_data:
        all_tools = []
        for s in summaries.values():
            all_tools.extend(s.get("tool_calls", []))
        failed = [tc for tc in all_tools if tc["status"] != "completed"]
        if failed:
            issues.append(f"- ⚠️ 有 {len(failed)} 个 tool 调用失败（含 subagent）")
        if main_dur and main_dur / 60000 > 30:
            issues.append(f"- ⚠️ 主 session 耗时较长 ({main_dur/60000:.1f} 分钟)")
    if not issues:
        issues.append("- ✅ 未发现明显问题")
    lines.extend(issues)
    lines.append("")
    lines.append("---")
    lines.append("")
    return "\n".join(lines)


def main():
    if len(sys.argv) < 3:
        print("用法: python3 analyze-session.py <sessions-dir|session.json> <trajectory.jsonl>", file=sys.stderr)
        sys.exit(1)

    sessions_arg = sys.argv[1]
    trajectory_path = sys.argv[2]

    manifest, sessions = load_sessions(sessions_arg)
    trajectory = load_trajectory(trajectory_path)
    trajectory_data = analyze_trajectory(trajectory)

    report = generate_report(manifest, sessions, trajectory_data)
    print(report, end="")


if __name__ == "__main__":
    main()
