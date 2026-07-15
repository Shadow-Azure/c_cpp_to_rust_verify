# Subagent Session Capture — Design

**Date:** 2026-07-15
**Status:** Approved
**Branch:** `debug/subagent-session-probe` → implementation

## Background

The C→Rust eval pipeline (`evaluate.yml`) exports OpenCode sessions to analyze
the conversion process. It loops over `opencode session list` and exports each
ID. Problem: OpenCode's **task tool** (subagent dispatch) creates child sessions
that **do NOT appear in `opencode session list`** — so they were never exported.

Verified 2026-07-15 via `debug-opencode-session.yml` (run 29390340653):
- `opencode session list` returns only the top-level (main) session.
- `opencode export <subagent-id>` **works by ID** even though the session is
  absent from the list, returning the full transcript (info with own cost/tokens
  + all messages incl. tool calls & reasoning).
- The main session's `task` tool outputs embed each subagent's session ID:
  `<task id="ses_…">`.

Consequence: current eval reports under-count cost/tokens (the main session's
`info.cost` excludes subagent LLM usage) and lose all subagent-internal detail.
The real run 29342870112 had **9** subagent dispatches.

## Goal

Capture every subagent session's full transcript in the `opencode-sessions`
artifact, and surface aggregated (main + subagent) cost/token/tool stats plus a
per-subagent breakdown in the eval report. **Observability only** — never affects
scoring or pass/fail.

## Approach

Harvest subagent IDs from the main session's `task` outputs, then export each by
ID. Three changes:

### 1. New `scripts/export-all-sessions.py` (export orchestrator)

Replaces the inline export loop in `evaluate.yml`. Behavior:

1. `opencode session list --format json` → top-level session IDs (the mains).
2. Export each to `/tmp/opencode-sessions/session-<id>.json`.
3. **BFS harvest:** parse every exported session's `task` tool parts. For each:
   - `subagent_type`, `description` ← `state.input`
   - subagent ID ← regex `<task id="(ses_[A-Za-z0-9]+)"` on `state.output`
   - `status`, `callID` ← `state.status`, `part.callID`
   Export any not-yet-exported subagent ID (works by ID). Repeat until no new IDs
   (handles nested subagents), capped (≤ 50 sessions) as a safety bound.
4. Write `/tmp/opencode-sessions/manifest.json` — one entry per session:
   `{id, file, role: "main"|"subagent", parent, subagent_type, description, status}`.

**Structure:** harvest/parse logic lives in pure functions (no `opencode`
dependency) so it is unit-testable locally against a real session file. The
`opencode export` calls are subprocess invocations, isolated from the pure
parse layer.

**Robustness:** tolerate the `Exporting session: <id>` prefix line OpenCode
writes before the JSON body (skip to first `{`). Never abort the whole run on a
single failed export — log and continue.

### 2. Refactor `scripts/analyze-session.py` (aggregation)

- Accept a **sessions directory** (contains `manifest.json` + session files) as
  the first arg. A single `.json` arg remains supported (backward compat).
- Load all sessions via the manifest. Identify main vs subagent by `role`.
- **Aggregate** across all sessions: total cost, total tokens (input/output/
  reasoning/cache), total messages, total duration, merged tool-call stats.
- **New "Subagent breakdown" table:** one row per subagent —
  `type | description | cost | tokens | duration | messages | status`.
- Show cost as `主 session | subagent(N) | 合计` so the corrected accounting is
  explicit.
- Existing compile-trajectory analysis unchanged.

### 3. `.github/workflows/evaluate.yml`

- **Export step:** replace the inline loop with a call to
  `export-all-sessions.py` (writes sessions + `manifest.json` into
  `/tmp/opencode-sessions/`).
- **Upload step:** unchanged — already uploads the whole `/tmp/opencode-sessions/`
  directory, so subagent files + manifest are included automatically.
- **Analyze step:** pass the sessions **directory** to `analyze-session.py`
  instead of `ls session-*.json | head -1`.

## Report output (new sections)

```
### OpenCode Session 概览（含 subagent）
| 指标 | 主 session | subagent(N) | 合计 |
| 成本 | $0.91 | $0.37 | $1.28 |
| 输入 tokens | … | … | … |
| 消息数 | 190 | 87 | 277 |

### Subagent 明细
| # | 类型 | 描述 | 成本 | 耗时 | 消息 | 状态 |
| 1 | fix-compilation | fix rust-flashdb… | $0.05 | 2.1min | 14 | ✅ |
| …
```

## Artifact impact

`opencode-sessions` grows from 1 file (~150 KB compressed) to 1 main + N
subagent files + `manifest.json`. Real runs (9 subagents doing real work) may
reach several-to-tens of MB compressed. Acceptable (artifact limit 10 GB).
Full transcripts uploaded — no truncation.

## Testing

1. **Parse unit test (local, done):** harvest function against the real
   9-subagent main session → 9/9 IDs + types + descriptions extracted. ✅
2. **Aggregation unit test (local):** feed `analyze-session.py` the real main
   session + synthetic subagent records; verify totals + breakdown table.
3. **End-to-end:** run `evaluate.yml` once after the change; confirm the artifact
   contains subagent files + manifest and the report shows aggregated stats.

## Out of scope (YAGNI)

- No changes to the skill / conversion flow (separate repo).
- No drill-down into individual subagent tool calls (summary stats + breakdown
  table only).
- No scoring changes (observability only).
