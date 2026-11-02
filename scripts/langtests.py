#!/usr/bin/env python3
"""Run ../iets/tests/lang the way iets's tests/langtests.rs does.

eval-okay-*: stdout must equal the .exp file (with the tests dir as /pwd).
eval-fail-*: must exit nonzero without a signal.
Usage: langtests.py [BIN] [-v] [-k SUBSTR]
"""
import os, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
tests = os.path.normpath(os.path.join(here, "../../iets/tests"))
args = sys.argv[1:]
verbose = "-v" in args
filt = args[args.index("-k") + 1] if "-k" in args else ""
pos = [a for i, a in enumerate(args) if not a.startswith("-") and (i == 0 or args[i - 1] != "-k")]
binary = os.path.abspath(pos[0]) if pos else os.path.join(here, "../zig-out/bin/iets")

env = dict(os.environ, HOME="/fake-home", TEST_VAR="foo", NIX_PATH="lang/dir3:lang/dir4")
stems = sorted(f[:-4] for f in os.listdir(os.path.join(tests, "lang"))
               if f.endswith(".nix") and (f.startswith("eval-okay-") or f.startswith("eval-fail-")) and filt in f)
passed, failed = 0, []
for stem in stems:
    flags = []
    fp = os.path.join(tests, "lang", stem + ".flags")
    if os.path.exists(fp):
        flags = open(fp).readline().split()
    try:
        p = subprocess.run([binary, "eval", "--impure", "--strict", *flags, f"lang/{stem}.nix"],
                           cwd=tests, env=env, capture_output=True, timeout=30)
    except subprocess.TimeoutExpired:
        failed.append((stem, "timeout")); continue
    if stem.startswith("eval-fail-"):
        why = "should fail" if p.returncode == 0 else ("crashed" if p.returncode < 0 or p.returncode == 134 else None)
    else:
        exp = os.path.join(tests, "lang", stem + ".exp")
        if not os.path.exists(exp):
            continue
        want = open(exp, "rb").read().rstrip(b"\n")
        got = p.stdout.replace(tests.encode(), b"/pwd").rstrip(b"\n")
        why = None if got == want else ("output differs: " + (p.stderr.decode(errors="replace").strip().splitlines() or ["(no stderr)"])[-1][:200])
    if why:
        failed.append((stem, why))
    else:
        passed += 1
for stem, why in failed:
    if verbose:
        print(f"FAIL {stem}: {why}")
print(f"{passed} passed, {len(failed)} failed")
