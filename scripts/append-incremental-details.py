#!/usr/bin/env python3
"""Read incremental-progress.json and output a markdown table for eval-report.md.

OBSERVABILITY ONLY — never affects scoring or pass/fail.

Usage:
    python3 scripts/append-incremental-details.py <progress.json>

Reads the JSON file (array of ModuleProgress objects) and prints a markdown
table to stdout.  Exits silently (no output, exit 0) when the file is
missing, empty, or contains invalid JSON.

Fields rendered:
  module, first_structural_errors, structural_fixes_applied,
  residual_after_structural, ai_fix_rounds, errors_after_each_round (joined with arrow),
  tests_generated (checkmark/cross), and a totals row.
"""
import json
import sys


def main():
    if len(sys.argv) < 2:
        print(
            "Usage: append-incremental-details.py <progress.json>",
            file=sys.stderr,
        )
        sys.exit(1)

    path = sys.argv[1]
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        # Silent exit: no progress file or malformed JSON
        sys.exit(0)

    if not data or not isinstance(data, list):
        sys.exit(0)

    # Markdown header
    print("")
    print("## Incremental Assembly Details")
    print("")
    print(
        "| Module | First Structural Errors | Structural Fixes | "
        "Residual After Structural | AI Fix Rounds | "
        "Errors After Each Round | Tests |"
    )
    print(
        "|--------|------------------------|-----------------|"
        "--------------------------|---------------|"
        "-------------------------|-------|"
    )

    total_first = 0
    total_fixes = 0
    total_residual = 0
    total_ai_rounds = 0
    tested = 0

    for entry in data:
        if not isinstance(entry, dict):
            continue
        name = entry.get("module", "?")
        first = entry.get("first_structural_errors", 0)
        fixes = entry.get("structural_fixes_applied", 0)
        residual = entry.get("residual_after_structural", 0)
        ai_rounds = entry.get("ai_fix_rounds", 0)
        rounds = entry.get("errors_after_each_round", [])
        tests = entry.get("tests_generated", False)

        total_first += first
        total_fixes += fixes
        total_residual += residual
        total_ai_rounds += ai_rounds
        if tests:
            tested += 1

        rounds_str = "→".join(str(r) for r in rounds) if rounds else "—"
        tests_str = "✅" if tests else "❌"

        print(
            f"| {name} | {first} | {fixes} | {residual} | "
            f"{ai_rounds} | {rounds_str} | {tests_str} |"
        )

    print(
        f"| **Total** | **{total_first}** | **{total_fixes}** | "
        f"**{total_residual}** | **{total_ai_rounds}** | | "
        f"**{tested}/{len(data)}** |"
    )


if __name__ == "__main__":
    main()
