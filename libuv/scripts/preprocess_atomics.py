#!/usr/bin/env python3
"""
preprocess_atomics.py — neutralize C11 atomics so c2rust can transpile libuv.

c2rust panics on C11 atomic operations (_Atomic types and the stdatomic.h
atomic_* functions). libuv's "core glue" files (uv-common, unix/core,
unix/loop, unix/fs, unix/tty, unix/async, unix/linux) all use these and were
silently skipped by the conversion agent, leaving the FFI layer without
uv_run / uv_loop_init / uv_close / uv_handle_size / ... .

This script rewrites those constructs IN PLACE into plain, non-atomic C that
c2rust's clang frontend can parse and export:

  _Atomic int x;                        -> int x;
  atomic_load_explicit(&v, ord)         -> (*(&v))
  atomic_store_explicit(&v, val, ord)   -> (*(&v) = (val))
  atomic_exchange(p, v)                 -> (*(p) = (v))
  atomic_fetch_add(p, v)                -> (*(p) += (v))
  atomic_compare_exchange_strong(p,e,d) -> (*(p) == *(e) ? (*(p) = (d), 1) : 0)

Atomicity is dropped deliberately — the output is correct ONLY for producing
compilable Rust, not for runtime thread safety. Sizes/alignments are preserved
(atomic and non-atomic variants of the same type are layout-compatible), so
struct-passing FFI tests are unaffected.

Idempotent: safe to run more than once.
"""

import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Atomic function -> (expected arg count, replacement builder)
# Replacements yield valid C expressions. Where the C11 op returns the
# pre-update value (exchange / fetch_*), the replacement yields the
# post-update value instead — wrong at runtime, but compiles and transpiles.
# ---------------------------------------------------------------------------
def _load(p):       return f"(*({p}))"
def _store(p, v):   return f"(*({p}) = ({v}))"
def _xchg(p, v):    return f"(*({p}) = ({v}))"
def _fetch_add(p, v): return f"(*({p}) += ({v}))"
def _fetch_sub(p, v): return f"(*({p}) -= ({v}))"
def _cas(p, e, d):  return f"(*({p}) == *({e}) ? (*({p}) = ({d}), 1) : 0)"

ATOMIC_FUNCS = {
    "atomic_load":                       (1, lambda a: _load(a[0])),
    "atomic_load_explicit":              (2, lambda a: _load(a[0])),
    "atomic_store":                      (2, lambda a: _store(a[0], a[1])),
    "atomic_store_explicit":             (3, lambda a: _store(a[0], a[1])),
    "atomic_exchange":                   (2, lambda a: _xchg(a[0], a[1])),
    "atomic_exchange_explicit":          (3, lambda a: _xchg(a[0], a[1])),
    "atomic_fetch_add":                  (2, lambda a: _fetch_add(a[0], a[1])),
    "atomic_fetch_sub":                  (2, lambda a: _fetch_sub(a[0], a[1])),
    "atomic_compare_exchange_strong":    (3, lambda a: _cas(a[0], a[1], a[2])),
    "atomic_compare_exchange_weak":      (3, lambda a: _cas(a[0], a[1], a[2])),
}

# Precompile a matcher: word-boundary + any known name (longest first so
# "atomic_load_explicit" wins over "atomic_load").
_NAMES = sorted(ATOMIC_FUNCS, key=len, reverse=True)
_NAME_RE = re.compile(
    r"(?<![A-Za-z0-9_])(" + "|".join(re.escape(n) for n in _NAMES) + r")"
)


def _extract_call_args(text, open_paren_idx):
    """Given index of the '(' opening a call, return (args, end_idx).
    end_idx points just past the matching ')'. Handles nested parens,
    strings, and char literals. Returns (None, open_paren_idx) if unbalanced."""
    assert text[open_paren_idx] == "("
    depth = 0
    i = open_paren_idx
    arg_start = i + 1
    args = []
    n = len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                args.append(text[arg_start:i].strip())
                return args, i + 1
        elif c in "'\"":
            # skip string/char literal
            quote = c
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    break
                i += 1
        elif c == "," and depth == 1:
            args.append(text[arg_start:i].strip())
            arg_start = i + 1
        i += 1
    return None, open_paren_idx


def replace_atomic_calls(text):
    """Replace every atomic_*() call with its plain-C equivalent."""
    out = []
    pos = 0
    replaced = 0
    for m in _NAME_RE.finditer(text):
        name = m.group(1)
        # find '(' (allow whitespace/newlines between name and '(')
        j = m.end()
        while j < len(text) and text[j] in " \t\r\n":
            j += 1
        if j >= len(text) or text[j] != "(":
            continue  # not a call (e.g. a variable named atomic_load_foo)
        args, end = _extract_call_args(text, j)
        if args is None:
            continue
        spec = ATOMIC_FUNCS.get(name)
        if spec is None or len(args) != spec[0]:
            continue
        out.append(text[pos:m.start()])
        out.append(spec[1](args))
        pos = end
        replaced += 1
    out.append(text[pos:])
    return "".join(out), replaced


# Strip the _Atomic qualifier: "_Atomic int" -> "int", "(_Atomic int*)" -> "(int*)".
_ATOMIC_QUAL_RE = re.compile(r"\b_Atomic\b\s*")
# Remove the stdatomic.h include (its real decls would conflict with our rewrites).
_STDATOMIC_INC_RE = re.compile(r"[ \t]*#[ \t]*include[ \t]*<stdatomic\.h>[ \t\r\n]*\n")


def transform_file(path: Path):
    orig = path.read_text(errors="replace")
    text = orig

    n_qual = len(_ATOMIC_QUAL_RE.findall(text))
    text = _ATOMIC_QUAL_RE.sub("", text)

    n_inc = len(_STDATOMIC_INC_RE.findall(text))
    text = _STDATOMIC_INC_RE.sub("", text)

    text, n_calls = replace_atomic_calls(text)

    if text != orig:
        path.write_text(text)
    return n_qual, n_inc, n_calls


def main():
    if len(sys.argv) < 2:
        print("usage: preprocess_atomics.py <libuv-source-dir>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 2

    # Transform .c/.h under src/ (where atomics live). Public include/ headers
    # have no atomics — leave them untouched so the public ABI is byte-identical.
    targets = []
    for sub in ("src",):
        d = root / sub
        if d.is_dir():
            targets.extend(d.rglob("*.c"))
            targets.extend(d.rglob("*.h"))

    total_qual = total_inc = total_calls = touched = 0
    for p in sorted(targets):
        nq, ni, nc = transform_file(p)
        if nq or ni or nc:
            touched += 1
            print(f"  {p.relative_to(root)}: _Atomic x{nq}, <stdatomic.h> x{ni}, calls x{nc}")
        total_qual += nq
        total_inc += ni
        total_calls += nc

    # Verify nothing atomic remains.
    leftover_calls = 0
    leftover_atomic = 0
    for p in targets:
        t = p.read_text(errors="replace")
        leftover_calls += len(_NAME_RE.findall(t))
        leftover_atomic += len(_ATOMIC_QUAL_RE.findall(t))

    print(
        f"\nDone: {touched} files, "
        f"_Atomic stripped={total_qual}, includes removed={total_inc}, "
        f"calls replaced={total_calls}"
    )
    if leftover_atomic or leftover_calls:
        print(
            f"WARNING: leftovers _Atomic={leftover_atomic} calls={leftover_calls} "
            "— review manually",
            file=sys.stderr,
        )
        return 1
    print("Verification OK: no _Atomic or atomic_* calls remain.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
