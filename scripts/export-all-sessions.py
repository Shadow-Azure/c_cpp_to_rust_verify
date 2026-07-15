#!/usr/bin/env python3
"""
export-all-sessions.py — 导出 OpenCode 的全部 session（顶层 session + task 派生的 subagent session）

OpenCode 的 `opencode session list` 只返回顶层 session；task 工具派生的 subagent
session 不在列表里，但可以用 ID 直接 `opencode export` 导出（2026-07-15 已验证）。

本脚本：
  1. `opencode session list` 获取顶层 session ID
  2. 逐个 `opencode export` 导出到输出目录
  3. 解析每个 session 的 task 工具输出，收割 subagent session ID（BFS，可处理嵌套）
  4. 导出所有 subagent session
  5. 写 manifest.json，记录每个 session 的角色/父级/类型/状态/成本

OBSERVABILITY ONLY — 永不影响评分。

用法:
    python3 scripts/export-all-sessions.py <output-dir> [--opencode-bin opencode] [--max-sessions 50]
"""

import argparse
import json
import os
import re
import subprocess
import sys

# task 工具输出形如：<task id="ses_xxx" state="completed">
TASK_ID_RE = re.compile(r'<task id="(ses_[A-Za-z0-9]+)"')


def load_session_text(text: str) -> dict:
    """从文本加载 session JSON，跳过 OpenCode 可能写入的 'Exporting session:' 前缀。"""
    idx = text.find('{')
    if idx < 0:
        return {}
    try:
        return json.loads(text[idx:])
    except json.JSONDecodeError:
        return {}


def load_session_file(path: str) -> dict:
    """加载 session 文件。"""
    try:
        with open(path) as f:
            return load_session_text(f.read())
    except (FileNotFoundError, OSError):
        return {}


def extract_task_dispatches(session: dict) -> list:
    """
    提取 session 中所有 task 工具派发的 subagent 元数据。

    纯函数，不依赖 opencode —— 可脱离 CI 单测（对真实 session 文件跑）。

    返回: [{subagent_id, subagent_type, description, task_status, call_id}, ...]
    """
    dispatches = []
    for msg in session.get('messages', []):
        for part in msg.get('parts', []):
            if part.get('type') != 'tool' or part.get('tool') != 'task':
                continue
            state = part.get('state', {}) or {}
            inp = state.get('input', {}) or {}
            out = state.get('output', '') or ''
            m = TASK_ID_RE.search(out)
            dispatches.append({
                'subagent_id': m.group(1) if m else None,
                'subagent_type': inp.get('subagent_type'),
                'description': (inp.get('description') or '').strip(),
                'task_status': state.get('status'),
                'call_id': part.get('callID'),
            })
    return dispatches


def session_cost_summary(session: dict) -> dict:
    """提取一个 session 的成本/耗时/消息摘要（供 manifest 用）。"""
    info = session.get('info', {}) or {}
    t = info.get('time', {}) or {}
    created = t.get('created', 0)
    updated = t.get('updated', 0)
    duration_ms = (updated - created) if created and updated else 0
    return {
        'agent': info.get('agent'),
        'cost': info.get('cost', 0),
        'tokens': info.get('tokens', {}) or {},
        'duration_ms': duration_ms,
        'message_count': len(session.get('messages', [])),
    }


def run_export(opencode_bin: str, sid: str, out_path: str) -> bool:
    """
    调用 `opencode export <sid>`，把 JSON 写入 out_path。返回是否拿到有效 JSON。

    注意：不使用 capture_output=True（Python subprocess 的 stdout 管道在 Linux 上
    默认只有 64KB 缓冲区，session JSON 可能远大于此）。改用文件描述符直写，
    与旧版 evaluate.yml 的 shell 重定向 `opencode export $SID > file` 等效。
    """
    try:
        with open(out_path, 'w') as f:
            result = subprocess.run(
                [opencode_bin, 'export', sid],
                stdout=f, stderr=subprocess.PIPE, text=True, timeout=180,
            )
    except subprocess.TimeoutExpired:
        print(f"  ⚠️ export {sid} 超时", file=sys.stderr)
        return False
    except (FileNotFoundError, OSError) as e:
        print(f"  ⚠️ export {sid} 错误: {e}", file=sys.stderr)
        return False
    # opencode 把 "Exporting session: ..." 写到 stderr，JSON 写到 stdout（文件）。
    # 检查文件是否包含有效 JSON（跳过可能的前缀）。
    if result.returncode != 0:
        print(f"  ⚠️ export {sid} 失败 (exit {result.returncode}): {result.stderr[:200]}", file=sys.stderr)
        return False
    try:
        with open(out_path) as f:
            head = f.read(256)
        if '{' not in head:
            print(f"  ⚠️ export {sid} 输出无 JSON", file=sys.stderr)
            return False
    except OSError:
        return False
    return True


def session_list_ids(opencode_bin: str) -> list:
    """`opencode session list --format json` → 顶层 session ID 列表。"""
    try:
        result = subprocess.run(
            [opencode_bin, 'session', 'list', '--format', 'json'],
            capture_output=True, text=True, timeout=60,
        )
        sessions = json.loads(result.stdout)
        return [s.get('id') for s in sessions if s.get('id')]
    except Exception as e:
        print(f"⚠️ opencode session list 失败: {e}", file=sys.stderr)
        return []


def main():
    ap = argparse.ArgumentParser(description='导出全部 OpenCode session（含 subagent）')
    ap.add_argument('output_dir', help='session 文件 + manifest.json 输出目录')
    ap.add_argument('--opencode-bin', default='opencode')
    ap.add_argument('--max-sessions', type=int, default=50, help='安全上限，防止异常膨胀')
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    manifest = {}          # sid -> entry
    worklist = []          # [(sid, meta)] 待导出
    exported = set()

    # 1. 顶层 session
    top_ids = session_list_ids(args.opencode_bin)
    print(f"顶层 session: {len(top_ids)} 个")
    for sid in top_ids:
        worklist.append((sid, {
            'role': 'main', 'parent': None,
            'subagent_type': None, 'description': '', 'task_status': None,
        }))

    total = 0
    while worklist and total < args.max_sessions:
        sid, meta = worklist.pop(0)
        if not sid or sid in exported:
            continue
        exported.add(sid)
        total += 1
        out_path = os.path.join(args.output_dir, f'session-{sid}.json')
        print(f"导出 [{meta['role']}] {sid}")

        entry = {
            'id': sid,
            'file': os.path.basename(out_path),
            'role': meta['role'],
            'parent': meta['parent'],
            'subagent_type': meta['subagent_type'],
            'description': meta['description'],
            'task_status': meta['task_status'],
        }

        if not run_export(args.opencode_bin, sid, out_path):
            entry.update({'exported': False, 'cost': 0, 'tokens': {},
                          'duration_ms': 0, 'message_count': 0})
            manifest[sid] = entry
            continue

        session = load_session_file(out_path)
        summary = session_cost_summary(session)
        # subagent 的类型优先用收割时的元数据，回退到 session 自身的 agent 字段
        stype = meta['subagent_type'] or (summary['agent'] if meta['role'] == 'subagent' else None)
        entry.update({
            'exported': True,
            'subagent_type': stype,
            'cost': summary['cost'],
            'tokens': summary['tokens'],
            'duration_ms': summary['duration_ms'],
            'message_count': summary['message_count'],
        })
        manifest[sid] = entry

        # 2. 收割该 session 派发的 subagent（BFS，处理嵌套）
        for d in extract_task_dispatches(session):
            cid = d['subagent_id']
            if cid and cid not in exported:
                worklist.append((cid, {
                    'role': 'subagent', 'parent': sid,
                    'subagent_type': d['subagent_type'],
                    'description': d['description'],
                    'task_status': d['task_status'],
                }))

    if total >= args.max_sessions and worklist:
        print(f"⚠️ 达到 max-sessions 上限 ({args.max_sessions})，{len(worklist)} 个未导出",
              file=sys.stderr)

    # 3. 写 manifest.json（main 在前）
    order = {'main': 0, 'subagent': 1}
    manifest_list = sorted(manifest.values(),
                           key=lambda x: (order.get(x['role'], 9), x['id']))
    manifest_path = os.path.join(args.output_dir, 'manifest.json')
    with open(manifest_path, 'w') as f:
        json.dump(manifest_list, f, indent=2, ensure_ascii=False)

    main_n = sum(1 for x in manifest_list if x['role'] == 'main')
    sub_n = sum(1 for x in manifest_list if x['role'] == 'subagent')
    total_cost = sum(x.get('cost', 0) for x in manifest_list)
    print(f"\n✅ 完成: {main_n} 主 + {sub_n} subagent = {len(manifest_list)} session")
    print(f"   合计成本: ${total_cost:.4f}")
    print(f"   manifest: {manifest_path}")


if __name__ == '__main__':
    main()
