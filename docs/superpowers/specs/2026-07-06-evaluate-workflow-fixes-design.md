# Evaluate Workflow Fixes Design

**Date**: 2026-07-06
**Context**: Job #28787764042 hit the 90-minute timeout and was cancelled. Three issues need fixing.

## Issue 1: Timeout Extension

**Problem**: Convert job times out at 90 minutes.
**Fix**: Change `timeout-minutes: 90` → `timeout-minutes: 150` in `evaluate.yml` line 19.
**Decision**: Keep evaluate job at 60 minutes — evaluation complexity doesn't scale with conversion time.

## Issue 2: Upload Artifacts on Failure

**Problem**: "Upload converted Rust code" step has no `if: always()`, so partial conversion artifacts are lost on failure/timeout.
**Fix**: Add `if: always()` to the step at line 317.
**Note**: `if-no-files-found` defaults to `warn`, so if `rust-flashdb/` doesn't exist yet, the step won't fail.

## Issue 3: Subagent Session Export

**Problem**: Only the main opencode session is exported. Subagent sessions (from `generate-test-baseline-fn` and `safe-refactor-fn`) are not captured.
**Fix**: Export ALL sessions from `opencode session list`, not just `sessions[0]`.
**Decision**: The evaluate job's `analyze-session.py` continues to process only the main session. Subagent sessions are uploaded for manual inspection/debugging.

### Implementation

1. Modify "Export opencode session" step:
   - Get all session IDs from `opencode session list --format json`
   - Create `/tmp/opencode-sessions/` directory
   - Export each session to `session-{id}.json`

2. Update "Upload opencode session" artifact:
   - Change path from `/tmp/opencode-session.json` to `/tmp/opencode-sessions/`
   - Rename artifact from `opencode-session` to `opencode-sessions`

3. Update evaluate job's download step:
   - Change artifact name from `opencode-session` to `opencode-sessions`
   - Update path references in `analyze-session.py` call

## Files Changed

- `.github/workflows/evaluate.yml` — all three fixes
