#!/usr/bin/env python3
"""TOML errors against the Rust oracle: each input as a project iets.toml,
as IETS_CONFIG and through builtins.fromTOML; stderr, stdout and exit code
must match byte for byte.

usage: scripts/toml-parity.py [BIN]"""

import os, subprocess, sys, tempfile

CASES = [
 "a = 1\na = 2", "x = [1, 2", 'k = "unterminated', "k = 1 2", "k = 0x", "[a]\n[a]", "k = tru",
 "k = { a = 1, a = 2 }", "k = 1979-05-27T25:00:00Z", "k.v = 1\nk = 2", "[lint", "= 1", 'k = """\nx',
 # new
 "k =", "k = ", "k", "k\n", "[]", "[[]]", "[a", "[[a]", "[[a]\n", "[a]]", "]", "[a.]", "[.a]", "a..b = 1",
 "a. = 1", ".a = 1", "k = [1,,2]", "k = [,]", "k = [1 2]", "k = [1 = 2]", "k = {", "k = { a }", "k = { a = }",
 "k = { a = 1 b = 2 }", "k = { = 1 }", "k = { a = 1,, }", "k = { a = 1, }", "k = {a = 1\n}", "k = }", "k = ]",
 "k = { a = 1 ]", "k = { [ }", "k = { a { } }", "k = 1 # c\x01", "k = 1\r", "k = 1\rx", "# \x7f",
 "k = 'abc", "k = 'a\x01b'", 'k = "a\\qb"', 'k = "\\u12"', 'k = "\\uD800"', 'k = "\\U00110000"', 'k = "a\x01"',
 "k = '''abc", 'k = """a\\  b"""', 'k = """a\\\n  b"""', "k = '''\r'''",
 "k = 01", "k = 1__2", "k = _1", "k = 1_", "k = +0x1", "k = 0X1", "k = 0o9", "k = 0b2", "k = 0d10", "k = 0xg",
 "k = 1.", "k = .5", "k = 1e", "k = 1.5e+", "k = 1.e5", "k = 1e400", "k = -inf", "k = +nan", "k = infinity",
 "k = ++1", "k = 9223372036854775808", "k = 18446744073709551616", "k = 170141183460469231731687303715884105728",
 "k = -9223372036854775809", "k = 0xffffffffffffffff", "k = 99999999999999999999999999999999999999999",
 "k = hello", "k = hello world", "k = abc'''", 'k = abc"', "k = a'", 'k = x"""',
 "k = 1979-13-27", "k = 1979-02-30", "k = 1979-5-27", "k = 1979-05-27X07:32:00", "k = 1979-05-27T07:32",
 "k = 1979-05-27T07:32:00.Z", "k = 1979-05-27T07:32:00+25:00", "k = 1979-05-27T07:32:00+07", "k = 07:32:61",
 "k = 7:32:00", "k = 1979-05-27 07:32:00", "k = 1979-05-27T07:32:00Zx", "k = 1979-05-27T07:32:00.123456789123",
 "[a]\nb = 1\n[a.b]", "a = [1]\n[[a]]", "[[a]]\n[a]", "a = {}\na.b = 1", "a = {}\n[a.b]", "a.b = 1\n[a]",
 "[a.b]\n[a]\nb = 1", "a = 1\na.b = 2", "a = [1]\na.b = 2", "[a]\nx.y = 1\n[a.x]", "k = { a.b = 1, a = 2 }",
 "k = { a = {}, a.b = 1 }", "k = { a = [], a.b = 1 }", "\"a\nb\" = 1", "'''a''' = 1", '"""a""" = 1', "é = 1",
 "a b = 1", "a.b c = 1", "[a b]", "a = 1 # ok\nb = 2\nb = 3", "[a]\n[b]\n[a]", "a = 1\n[[a]]\nb = 0x",
 "a = [[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[[",
 "x = 1\n\n\n\n\n\n\n\n\n\n\nx = 2", "a = \"é\"\nb = é", "k = 'x' 'y'", "k = 1,", "k = [1]]", "k = \"a\" # c\nk = 2",
 "﻿a = 1\na = 2", "a = 1\r\na = 2", "[[a.b]]\n[a]\n[a.b]", "k = { a = 1 }\n[k]", "k = true\nbogus = 1", "zz = 1\naa = 2",
 "k = 1979-05-27T07:32:00Z\nbogus = 1", "lint = 1", "[lint]\nfoo = 1\n[lint]",
]
CASES += [
 "a = 1\nb = 'x'\nc = \"\"\"\n  multi \\\n  line\"\"\"\nd = '''\nraw\\n'''\ne = [1, 2.5, \"s\", [true]]\n[t]\nx.y = 1\n[[aot]]\nk = 1\n[[aot]]\nk = 2\n",
 "d = 1979-05-27T07:32:00.123456Z\nt = 07:32:00\nl = 1979-05-27\no = 1979-05-27T00:32:00-07:00\nf = 1e10\ng = -0.0\nh = 0xff\ni = 0o17\nj = 0b101\nk = +inf\nn = nan\n",
 "a = { b = 1,\n c = 2 }", "a = \"\\e\"", "t = 07:32", "a.b.c = 1\na.b.d = 2\n[a.e]\nf = 1", "\"quoted key\" = 1\n'lit key' = 2\n\"\" = 3",
 "a = [\n 1, # c\n 2,\n]", "a = 9223372036854775807\nb = -9223372036854775808", "a = 1_000_000\nb = 1_0.5e1_0",
 "s = \"\\u00e9\\U0001F600\\t\"", "x = 1979-05-27 07:32:00", "[a]\n[a.b]\n[a.c]\n[[a.d]]",
]
HERE = os.path.dirname(os.path.abspath(__file__))
RUST = os.path.join(HERE, "../../iets/target/release/iets")
ZIG = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "../zig-out-rel/bin/iets")
def run(b, text, mode):
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "a.nix"), "w").write("1\n")
        env = dict(os.environ)
        env["HOME"] = d; env["XDG_CONFIG_HOME"] = d + "/cfg"; env["XDG_CACHE_HOME"] = d + "/cache"
        if mode == "file":
            open(os.path.join(d, "iets.toml"), "w", newline="").write(text)
            cmd = [b, "eval", "--no-cache", "a.nix"]
        elif mode == "env":
            env["IETS_CONFIG"] = text
            cmd = [b, "eval", "--no-cache", "a.nix"]
        else:  # fromTOML
            cmd = [b, "eval", "--no-cache", "--expr", "builtins.fromTOML (builtins.readFile ./t.toml)"]
            open(os.path.join(d, "t.toml"), "w", newline="").write(text)
        r = subprocess.run(cmd, cwd=d, capture_output=True, env=env)
        return (r.returncode, r.stdout.decode(errors="replace"), r.stderr.decode(errors="replace").replace(d, "<D>"))
bad = 0
for mode in ("file", "env", "fromTOML"):
    for c in CASES:
        a, z = run(RUST, c, mode), run(ZIG, c, mode)
        if a != z:
            bad += 1
            print("=== %s %r" % (mode, c))
            print("--- rust (%d)\n%s%s" % (a[0], a[1], a[2]))
            print("--- zig (%d)\n%s%s" % (z[0], z[1], z[2]))
print("toml parity: %d cases, %d differ" % (3 * len(CASES), bad))
sys.exit(1 if bad else 0)
