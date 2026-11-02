//! POSIX extended regular expressions for `builtins.match` and `builtins.split`.
//!
//! Written from the observed behaviour of Nix's `builtins.match` and
//! `builtins.split` and from the POSIX ERE specification, not from libstdc++.
//! Where Nix departs from POSIX leftmost-longest, the observed rules are:
//!
//! - A search takes the leftmost start. From there every path is tried in
//!   priority order and the longest end wins; ties go to the first path.
//! - A greedy quantifier does not try fewer repetitions once the path with
//!   more repetitions reached any match, even a shorter one.
//! - A loop iteration that consumes nothing ends the loop, so `(a*)*` on
//!   "aa" captures "". Captures are not reset between iterations.
//! - `builtins.match` takes the first path in priority order that ends at
//!   the end of the input.
//! - Ranges compare bytes as signed chars; classes are the C locale's.
//! - The pattern size limit counts states as libstdc++'s `_Compiler` does.
//!
//! Matching backtracks with an explicit stack, so long inputs do not recurse.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Invalid, TooBig };
pub const CompileError = Error || Allocator.Error;

const ByteSet = std.StaticBitSet(256);

const state_limit: u64 = 99_995;
const none = std.math.maxInt(usize);

/// Portable character set names in code order; letters name themselves.
const names = "NUL SOH STX ETX EOT ENQ ACK alert backspace tab newline vertical-tab form-feed " ++
    "carriage-return SO SI DLE DC1 DC2 DC3 DC4 NAK SYN ETB CAN EM SUB ESC IS4 IS3 IS2 IS1 " ++
    "space exclamation-mark quotation-mark number-sign dollar-sign percent-sign ampersand " ++
    "apostrophe left-parenthesis right-parenthesis asterisk plus-sign comma hyphen period " ++
    "slash zero one two three four five six seven eight nine colon semicolon less-than-sign " ++
    "equals-sign greater-than-sign question-mark commercial-at A B C D E F G H I J K L M N " ++
    "O P Q R S T U V W X Y Z left-square-bracket backslash right-square-bracket circumflex " ++
    "underscore grave-accent a b c d e f g h i j k l m n o p q r s t u v w x y z " ++
    "left-curly-bracket vertical-line right-curly-bracket tilde " ++
    "DEL";

const Quant = union(enum) {
    star,
    plus,
    opt,
    /// `{m}`, `{m,}` (max null) and `{m,n}`.
    range: struct { min: u32, max: ?u32 },
};

const Node = union(enum) {
    byte: u8,
    set: ByteSet,
    any,
    bol,
    eol,
    group: struct { idx: u32, inner: *const Node },
    cat: []const Node,
    alt: []const Node,
    rep: struct { inner: *const Node, q: Quant },
};

fn single(c: u8) ByteSet {
    var s: ByteSet = .empty;
    s.set(c);
    return s;
}

/// Both cases of every ASCII letter the set holds. A bracket folds before it
/// is negated, so `[^a]` matches neither case.
fn foldCase(set: *ByteSet) void {
    var c: u8 = 'A';
    while (c <= 'Z') : (c += 1) {
        const both = set.isSet(c) or set.isSet(c + 32);
        set.setValue(c, both);
        set.setValue(c + 32, both);
    }
}

const Parser = struct {
    re: []const u8,
    i: usize = 0,
    groups: u32 = 0,
    depth: u32 = 0,
    states: u64 = 0,
    /// `std::regex::icase`: a letter matches in either case (the C locale's).
    icase: bool,
    arena: Allocator,

    const Res = CompileError;

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.re.len) p.re[p.i] else null;
    }

    fn next(p: *Parser) Res!u8 {
        const c = p.peek() orelse return error.Invalid;
        p.i += 1;
        return c;
    }

    fn box(p: *Parser, n: Node) Res!*const Node {
        const b = try p.arena.create(Node);
        b.* = n;
        return b;
    }

    fn alt(p: *Parser) Res!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(p.arena, try p.branch());
        while (p.peek() == '|') {
            p.i += 1;
            p.states += 3;
            try branches.append(p.arena, try p.branch());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn branch(p: *Parser) Res!Node {
        var items: std.ArrayList(Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or (c == ')' and p.depth > 0)) break;
            try items.append(p.arena, try p.piece());
        }
        if (items.items.len == 1) return items.items[0];
        return .{ .cat = items.items };
    }

    /// An atom and its quantifiers. With `s` the states of the quantified
    /// piece so far: `*` and `+` add 1, `?` adds 2, `{n}` adds s*n+1,
    /// `{n,}` adds s*(n+1)+1 and `{m,n}` adds s*n+(n-m)+1.
    fn piece(p: *Parser) Res!Node {
        const before = p.states;
        var node, const quantifiable = try p.atom();
        while (try p.quant()) |q| {
            if (!quantifiable) return error.Invalid;
            const s = p.states - before;
            p.states +|= switch (q) {
                .star, .plus => 1,
                .opt => 2,
                .range => |r| if (r.max) |n|
                    (s *| n) +| (n - r.min + 1)
                else
                    (s *| (@as(u64, r.min) + 1)) +| 1,
            };
            if (p.states > state_limit) {
                if (p.peek() == '\\') _ = p.escape() catch return error.Invalid;
                return error.TooBig;
            }
            // Boxed first: the result location of `node` must not alias its read.
            const inner = try p.box(node);
            node = .{ .rep = .{ .inner = inner, .q = q } };
        }
        return node;
    }

    fn atom(p: *Parser) Res!struct { Node, bool } {
        const c = try p.next();
        p.states += 1;
        const node: Node = switch (c) {
            '(' => blk: {
                const g = p.groups;
                p.groups += 1;
                p.depth += 1;
                p.states += 2;
                const inner = try p.alt();
                if (try p.next() != ')') return error.Invalid;
                p.depth -= 1;
                break :blk .{ .group = .{ .idx = g, .inner = try p.box(inner) } };
            },
            ')', '*', '+', '?', '{' => return error.Invalid,
            '^' => return .{ .bol, false },
            '$' => return .{ .eol, false },
            '.' => .any,
            '[' => .{ .set = try p.bracket() },
            '\\' => blk: {
                p.i -= 1;
                break :blk p.literal(try p.escape());
            },
            else => p.literal(c),
        };
        return .{ node, true };
    }

    /// One literal byte, as a set when it must match either case.
    fn literal(p: *const Parser, c: u8) Node {
        if (!p.icase or !std.ascii.isAlphabetic(c)) return .{ .byte = c };
        var set = single(c);
        foldCase(&set);
        return .{ .set = set };
    }

    fn escape(p: *Parser) Res!u8 {
        p.i += 1;
        const c = try p.next();
        if (std.mem.indexOfScalar(u8, "$()*+.?[\\^{|", c) == null) return error.Invalid;
        return c;
    }

    fn quant(p: *Parser) Res!?Quant {
        const q: Quant = switch (p.peek() orelse return null) {
            '*' => .star,
            '+' => .plus,
            '?' => .opt,
            '{' => blk: {
                p.i += 1;
                const m = try p.number() orelse return error.Invalid;
                var n: ?u32 = m;
                if (p.peek() == ',') {
                    p.i += 1;
                    n = try p.number();
                }
                if (p.peek() != '}') return error.Invalid;
                if (n) |nn| if (nn < m) return error.Invalid;
                break :blk .{ .range = .{ .min = m, .max = n } };
            },
            else => return null,
        };
        p.i += 1;
        return q;
    }

    fn number(p: *Parser) Res!?u32 {
        const start = p.i;
        var v: u64 = 0;
        while (p.peek()) |d| {
            if (!std.ascii.isDigit(d)) break;
            v = v * 10 + (d - '0');
            if (v > std.math.maxInt(i32)) return error.Invalid;
            p.i += 1;
        }
        return if (p.i > start) @intCast(v) else null;
    }

    fn isClassOpen(c: ?u8) bool {
        return c == ':' or c == '=' or c == '.';
    }

    fn bracket(p: *Parser) Res!ByteSet {
        var set: ByteSet = .empty;
        const negate = p.peek() == '^';
        if (negate) p.i += 1;
        var first = true;
        var prev: ?u8 = null;
        while (true) : (first = false) {
            const c = try p.next();
            if (c == ']' and !first) break;
            if (c == '[' and isClassOpen(p.peek())) {
                const kind = try p.next();
                const name = try p.bracketName(kind);
                prev = null;
                switch (kind) {
                    ':' => try addClass(&set, name),
                    '=' => {
                        const b = try namedChar(name);
                        set.set(std.ascii.toLower(b));
                        set.set(std.ascii.toUpper(b));
                    },
                    else => {
                        const b = try namedChar(name);
                        set.set(b);
                        prev = b;
                    },
                }
            } else if (c == '-' and !first and p.peek() != ']') {
                const lo = prev orelse return error.Invalid;
                prev = null;
                const hi = try p.next();
                if (hi == '[' and isClassOpen(p.peek())) return error.Invalid;
                const slo: i8 = @bitCast(lo);
                const shi: i8 = @bitCast(hi);
                if (slo > shi) return error.Invalid;
                var b: i16 = slo;
                while (b <= shi) : (b += 1) set.set(@as(u8, @bitCast(@as(i8, @intCast(b)))));
            } else {
                set.set(c);
                prev = c;
            }
        }
        if (p.icase) foldCase(&set);
        if (negate) set.toggleAll();
        return set;
    }

    fn bracketName(p: *Parser, kind: u8) Res![]const u8 {
        const start = p.i;
        const len = std.mem.indexOf(u8, p.re[start..], &.{ kind, ']' }) orelse return error.Invalid;
        p.i = start + len + 2;
        return p.re[start .. start + len];
    }
};

fn namedChar(name: []const u8) Error!u8 {
    var it = std.mem.splitScalar(u8, names, ' ');
    var i: u8 = 0;
    while (it.next()) |n| : (i += 1) {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return error.Invalid;
}

fn addClass(set: *ByteSet, name: []const u8) Error!void {
    const Class = enum { alnum, alpha, blank, cntrl, digit, d, graph, lower, print, punct, space, s, upper, xdigit, w };
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return error.Invalid;
    const cls = std.meta.stringToEnum(Class, std.ascii.lowerString(&buf, name)) orelse return error.Invalid;
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        const graphic = c >= 0x21 and c <= 0x7e;
        const in = switch (cls) {
            .alnum => std.ascii.isAlphanumeric(c),
            .alpha => std.ascii.isAlphabetic(c),
            .blank => c == ' ' or c == '\t',
            .cntrl => c < 0x20 or c == 0x7f,
            .digit, .d => std.ascii.isDigit(c),
            .graph => graphic,
            .lower => std.ascii.isLower(c),
            .print => graphic or c == ' ',
            .punct => graphic and !std.ascii.isAlphanumeric(c),
            .space, .s => c == ' ' or (c >= '\t' and c <= '\r'),
            .upper => std.ascii.isUpper(c),
            .xdigit => std.ascii.isHex(c),
            .w => std.ascii.isAlphanumeric(c) or c == '_',
        };
        if (in) set.set(c);
    }
}

const Inst = union(enum) {
    byte: u8,
    set: u32,
    any,
    bol,
    eol,
    /// Write the position to a register (capture bound or loop mark).
    save: u32,
    clear: u32,
    /// Run the next instruction, then on failure the target.
    fork: u32,
    jmp: u32,
    /// Greedy: run the next instruction; the target runs only if that
    /// found no match at all.
    opt: u32,
    /// Loop back to `body` unless the iteration that started at the mark
    /// consumed nothing; the exit is the next instruction, as for `opt`.
    loop: struct { mark: u32, body: u32 },
    /// Greedy repetition of a one-byte set, `min1` for `+`.
    star: struct { set: u32, min1: bool },
    match,
};

pub const Prog = struct {
    insts: []const Inst,
    sets: []const ByteSet,
    ncaps: usize,
    nregs: usize,
    /// Bytes a non-empty match can start with; null if it can be empty.
    first: ?ByteSet,
    anchored: bool,

    pub fn deinit(p: *Prog, gpa: Allocator) void {
        gpa.free(p.insts);
        gpa.free(p.sets);
    }
};

const Compiler = struct {
    gpa: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    sets: std.ArrayList(ByteSet) = .empty,
    nregs: u32,

    fn push(c: *Compiler, i: Inst) Allocator.Error!usize {
        try c.insts.append(c.gpa, i);
        return c.insts.items.len - 1;
    }

    fn here(c: *const Compiler) u32 {
        return @intCast(c.insts.items.len);
    }

    fn patch(c: *Compiler, at: usize) void {
        const to = c.here();
        switch (c.insts.items[at]) {
            .fork, .jmp, .opt => |*t| t.* = to,
            else => unreachable,
        }
    }

    fn addSet(c: *Compiler, s: ByteSet) Allocator.Error!u32 {
        try c.sets.append(c.gpa, s);
        return @intCast(c.sets.items.len - 1);
    }

    fn emit(c: *Compiler, n: *const Node) Allocator.Error!void {
        switch (n.*) {
            .byte => |b| _ = try c.push(.{ .byte = b }),
            .set => |s| _ = try c.push(.{ .set = try c.addSet(s) }),
            .any => _ = try c.push(.any),
            .bol => _ = try c.push(.bol),
            .eol => _ = try c.push(.eol),
            .group => |g| {
                _ = try c.push(.{ .save = 2 * g.idx });
                try c.emit(g.inner);
                _ = try c.push(.{ .save = 2 * g.idx + 1 });
            },
            .cat => |items| for (items) |*i| try c.emit(i),
            .alt => |branches| {
                var ends: std.ArrayList(usize) = .empty;
                defer ends.deinit(c.gpa);
                for (branches, 0..) |*b, k| {
                    if (k + 1 == branches.len) {
                        try c.emit(b);
                    } else {
                        const f = try c.push(.{ .fork = 0 });
                        try c.emit(b);
                        try ends.append(c.gpa, try c.push(.{ .jmp = 0 }));
                        c.patch(f);
                    }
                }
                for (ends.items) |e| c.patch(e);
            },
            .rep => |r| switch (r.q) {
                .star => try c.star(r.inner, false),
                .plus => try c.star(r.inner, true),
                .opt => {
                    const o = try c.push(.{ .opt = 0 });
                    try c.emit(r.inner);
                    c.patch(o);
                },
                .range => |rg| {
                    for (0..rg.min) |_| try c.emit(r.inner);
                    if (rg.max) |max| {
                        var opts: std.ArrayList(usize) = .empty;
                        defer opts.deinit(c.gpa);
                        for (rg.min..max) |_| {
                            try opts.append(c.gpa, try c.push(.{ .opt = 0 }));
                            try c.emit(r.inner);
                        }
                        for (opts.items) |o| c.patch(o);
                    } else try c.star(r.inner, false);
                },
            },
        }
    }

    fn star(c: *Compiler, inner: *const Node, min1: bool) Allocator.Error!void {
        const one: ?ByteSet = switch (inner.*) {
            .byte => |b| single(b),
            .set => |s| s,
            .any => blk: {
                var s: ByteSet = .full;
                s.unset(0);
                break :blk s;
            },
            else => null,
        };
        if (one) |s| {
            _ = try c.push(.{ .star = .{ .set = try c.addSet(s), .min1 = min1 } });
            return;
        }
        const mark = c.nregs;
        c.nregs += 1;
        var skip: ?usize = null;
        if (!min1) {
            _ = try c.push(.{ .clear = mark });
            skip = try c.push(.{ .jmp = 0 });
        }
        const body = c.here();
        _ = try c.push(.{ .save = mark });
        try c.emit(inner);
        if (skip) |j| c.patch(j);
        _ = try c.push(.{ .loop = .{ .mark = mark, .body = body } });
    }
};

/// Bytes that can start a match, or null if a match can be empty. With
/// `stop_at_bol`, paths through `^` are dropped.
fn firstBytes(gpa: Allocator, insts: []const Inst, sets: []const ByteSet, stop_at_bol: bool) Allocator.Error!?ByteSet {
    var out: ByteSet = .empty;
    const seen = try gpa.alloc(bool, insts.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var work: std.ArrayList(usize) = .empty;
    defer work.deinit(gpa);
    try work.append(gpa, 0);
    while (work.pop()) |pc| {
        if (seen[pc]) continue;
        seen[pc] = true;
        switch (insts[pc]) {
            .byte => |b| out.set(b),
            .set => |s| out.setUnion(sets[s]),
            .any => {
                var s: ByteSet = .full;
                s.unset(0);
                out.setUnion(s);
            },
            .star => |s| {
                out.setUnion(sets[s.set]);
                if (!s.min1) try work.append(gpa, pc + 1);
            },
            .bol => if (!stop_at_bol) try work.append(gpa, pc + 1),
            .save, .clear => try work.append(gpa, pc + 1),
            .eol, .match => return null,
            .fork, .opt => |t| try work.appendSlice(gpa, &.{ pc + 1, t }),
            .jmp => |t| try work.append(gpa, t),
            .loop => |l| try work.appendSlice(gpa, &.{ pc + 1, l.body }),
        }
    }
    return out;
}

pub fn compile(gpa: Allocator, re: []const u8) CompileError!Prog {
    return compileOpt(gpa, re, false);
}

/// `compile`, with `std::regex::icase` when `icase`.
pub fn compileOpt(gpa: Allocator, re: []const u8, icase: bool) CompileError!Prog {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var p: Parser = .{ .re = re, .icase = icase, .arena = arena.allocator() };
    const node = try p.alt();
    if (p.i < re.len) return error.Invalid;
    const ncaps = 2 * @as(usize, p.groups);
    var c: Compiler = .{ .gpa = gpa, .nregs = @intCast(ncaps) };
    errdefer c.insts.deinit(gpa);
    errdefer c.sets.deinit(gpa);
    try c.emit(&node);
    _ = try c.push(.match);
    const first = try firstBytes(gpa, c.insts.items, c.sets.items, false);
    const from_bol = try firstBytes(gpa, c.insts.items, c.sets.items, true);
    const anchored = if (from_bol) |s| s.count() == 0 else false;
    const insts = try c.insts.toOwnedSlice(gpa);
    errdefer gpa.free(insts);
    return .{
        .insts = insts,
        .sets = try c.sets.toOwnedSlice(gpa),
        .ncaps = ncaps,
        .nregs = c.nregs,
        .first = first,
        .anchored = anchored,
    };
}

const Frame = union(enum) {
    fork: struct { pc: u32, pos: usize },
    /// Exit to `pc` at `pos` unless a match was seen since the push.
    opt: struct { pc: u32, pos: usize, seen: u64 },
    /// As `opt` for each exit position `lo..=hi`, highest first.
    star: struct { pc: u32, lo: usize, hi: usize, seen: u64 },
    reg: struct { r: u32, old: usize },
};

const Mode = union(enum) {
    full,
    search: struct { not_null: bool },
};

/// A capture group's bounds.
pub const Group = struct { start: usize, end: usize };

/// Running a program over one input. Holds its buffers, so one `Exec`
/// serves every search over that input.
pub const Exec = struct {
    gpa: Allocator,
    prog: *const Prog,
    hay: []const u8,
    regs: []usize,
    /// The registers of the best match the last run found.
    best: []usize,
    stack: std.ArrayList(Frame) = .empty,
    /// Matches reached so far; see `Frame.opt`.
    seen: u64 = 0,

    pub fn init(gpa: Allocator, prog: *const Prog, hay: []const u8) Allocator.Error!Exec {
        const regs = try gpa.alloc(usize, prog.nregs);
        errdefer gpa.free(regs);
        return .{ .gpa = gpa, .prog = prog, .hay = hay, .regs = regs, .best = try gpa.alloc(usize, prog.nregs) };
    }

    pub fn deinit(ex: *Exec) void {
        ex.gpa.free(ex.regs);
        ex.gpa.free(ex.best);
        ex.stack.deinit(ex.gpa);
    }

    /// Capture group `i` of the last match.
    pub fn group(ex: *const Exec, i: usize) ?Group {
        const a = ex.best[2 * i];
        const b = ex.best[2 * i + 1];
        if (a == none or b == none or a > b) return null;
        return .{ .start = a, .end = b };
    }

    pub fn ngroups(ex: *const Exec) usize {
        return ex.prog.ncaps / 2;
    }

    fn setReg(ex: *Exec, r: u32, v: usize) Allocator.Error!bool {
        try ex.stack.append(ex.gpa, .{ .reg = .{ .r = r, .old = ex.regs[r] } });
        ex.regs[r] = v;
        return true;
    }

    /// The end of the match starting at `start`; its registers are in `best`.
    fn run(ex: *Exec, start: usize, mode: Mode) Allocator.Error!?usize {
        const insts = ex.prog.insts;
        const sets = ex.prog.sets;
        const hay = ex.hay;
        const len = hay.len;
        @memset(ex.regs, none);
        ex.stack.clearRetainingCapacity();
        var best: ?usize = null;
        var pc: usize = 0;
        var pos = start;
        run: while (true) {
            const ok = switch (insts[pc]) {
                .byte => |b| eat(pos < len and hay[pos] == b, &pos),
                .set => |s| eat(pos < len and sets[s].isSet(hay[pos]), &pos),
                .any => eat(pos < len and hay[pos] != 0, &pos),
                .bol => pos == 0,
                .eol => pos == len,
                .save => |r| try ex.setReg(r, pos),
                .clear => |r| try ex.setReg(r, none),
                .fork => |t| blk: {
                    try ex.stack.append(ex.gpa, .{ .fork = .{ .pc = t, .pos = pos } });
                    break :blk true;
                },
                .opt => |t| blk: {
                    try ex.stack.append(ex.gpa, .{ .opt = .{ .pc = t, .pos = pos, .seen = ex.seen } });
                    break :blk true;
                },
                .jmp => |t| {
                    pc = t;
                    continue :run;
                },
                .loop => |l| blk: {
                    if (ex.regs[l.mark] != pos) {
                        try ex.stack.append(ex.gpa, .{ .opt = .{ .pc = @intCast(pc + 1), .pos = pos, .seen = ex.seen } });
                        pc = l.body;
                        continue :run;
                    }
                    break :blk true;
                },
                .star => |st| blk: {
                    const s = &sets[st.set];
                    const lo = pos + @intFromBool(st.min1);
                    var end = pos;
                    while (end < len and s.isSet(hay[end])) end += 1;
                    if (end > lo) try ex.stack.append(ex.gpa, .{ .star = .{ .pc = @intCast(pc + 1), .lo = lo, .hi = end - 1, .seen = ex.seen } });
                    pos = end;
                    break :blk end >= lo;
                },
                .match => switch (mode) {
                    .full => if (pos == len) {
                        @memcpy(ex.best, ex.regs);
                        return pos;
                    } else false,
                    .search => |m| blk: {
                        if (m.not_null and pos == start) break :blk false;
                        ex.seen += 1;
                        if (best == null or pos > best.?) {
                            best = pos;
                            @memcpy(ex.best, ex.regs);
                        }
                        if (pos == len) break :run;
                        break :blk false;
                    },
                },
            };
            if (ok) {
                pc += 1;
                continue;
            }
            while (true) {
                const f = ex.stack.pop() orelse break :run;
                switch (f) {
                    .reg => |r| {
                        ex.regs[r.r] = r.old;
                        continue;
                    },
                    .fork => |x| {
                        pc = x.pc;
                        pos = x.pos;
                    },
                    .opt => |x| {
                        if (x.seen != ex.seen) continue;
                        pc = x.pc;
                        pos = x.pos;
                    },
                    .star => |x| {
                        if (x.seen != ex.seen) continue;
                        if (x.hi > x.lo) try ex.stack.append(ex.gpa, .{ .star = .{ .pc = x.pc, .lo = x.lo, .hi = x.hi - 1, .seen = x.seen } });
                        pc = x.pc;
                        pos = x.hi;
                    },
                }
                break;
            }
        }
        return best;
    }

    fn search(ex: *Exec, from: usize, continuous: bool, not_null: bool) Allocator.Error!?Match {
        const len = ex.hay.len;
        var start = from;
        while (start <= len) : (start += 1) {
            if (ex.prog.anchored and start > 0) return null;
            const viable = if (ex.prog.first) |f| start < len and f.isSet(ex.hay[start]) else true;
            if (viable) {
                if (try ex.run(start, .{ .search = .{ .not_null = not_null } })) |end|
                    return .{ .start = start, .end = end };
            }
            if (continuous) return null;
        }
        return null;
    }

    /// Whether the whole input matches; the groups are then `group(i)`.
    pub fn matchExact(ex: *Exec) Allocator.Error!bool {
        if (ex.prog.first) |f| {
            if (ex.hay.len == 0 or !f.isSet(ex.hay[0])) return false;
        }
        return try ex.run(0, .full) != null;
    }
};

fn eat(ok: bool, pos: *usize) bool {
    pos.* += @intFromBool(ok);
    return ok;
}

pub const Match = struct { start: usize, end: usize };

/// Successive matches in `std::regex_iterator` order: after an empty match
/// a non-empty one is tried at the same position before moving one byte on.
/// The groups of the match `next` returned are `exec.group(i)`.
pub const Matches = struct {
    exec: Exec,
    prev: ?Match = null,
    done: bool = false,

    pub fn init(gpa: Allocator, prog: *const Prog, hay: []const u8) Allocator.Error!Matches {
        return .{ .exec = try .init(gpa, prog, hay) };
    }

    pub fn deinit(m: *Matches) void {
        m.exec.deinit();
    }

    pub fn next(m: *Matches) Allocator.Error!?Match {
        if (m.done) return null;
        const ex = &m.exec;
        const r = if (m.prev) |p|
            (if (p.start < p.end)
                try ex.search(p.end, false, false)
            else if (p.end < ex.hay.len)
                (try ex.search(p.end, true, true)) orelse try ex.search(p.end + 1, false, false)
            else
                null)
        else
            try ex.search(0, false, false);
        m.prev = r;
        if (r == null) m.done = true;
        return r;
    }
};

const testing = std.testing;

fn expectCaps(re: []const u8, s: []const u8, want: ?[]const ?[]const u8) !void {
    var p = try compile(testing.allocator, re);
    defer p.deinit(testing.allocator);
    var ex: Exec = try .init(testing.allocator, &p, s);
    defer ex.deinit();
    const ok = try ex.matchExact();
    const w = want orelse return testing.expect(!ok);
    try testing.expect(ok);
    try testing.expectEqual(w.len, ex.ngroups());
    for (w, 0..) |g, i| {
        const got = ex.group(i);
        if (g) |gs| {
            try testing.expectEqualStrings(gs, s[got.?.start..got.?.end]);
        } else try testing.expect(got == null);
    }
}

test "long inputs do not recurse" {
    const s = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(s);
    for (s, 0..) |*c, i| c.* = if (i % 2 == 0) 'a' else 'b';
    try expectCaps("(a|b)*", s, &.{"b"});
    try expectCaps("((a)(b))*x", s, null);
    var p = try compile(testing.allocator, "(a|b)");
    defer p.deinit(testing.allocator);
    var m: Matches = try .init(testing.allocator, &p, s);
    defer m.deinit();
    var n: usize = 0;
    while (try m.next()) |_| n += 1;
    try testing.expectEqual(200_000, n);
}

test "names" {
    var it = std.mem.splitScalar(u8, names, ' ');
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    try testing.expectEqual(128, n);
    try testing.expectEqual('-', try namedChar("hyphen"));
    try testing.expectEqual('~', try namedChar("tilde"));
    try testing.expectEqual(127, try namedChar("DEL"));
}

test "size limit" {
    const gpa = testing.allocator;
    var ok = try compile(gpa, "a{99993}");
    ok.deinit(gpa);
    try testing.expectError(error.TooBig, compile(gpa, "a{99994}"));
    try testing.expectError(error.TooBig, compile(gpa, "(a){24998}"));
    try testing.expectError(error.Invalid, compile(gpa, "a{99999}\\"));
    try testing.expectError(error.Invalid, compile(gpa, "a{2147483648}"));
}

test "groups and semantics" {
    try expectCaps("(a*)*", "aa", &.{""});
    try expectCaps("a(b)?c", "ac", &.{null});
    try expectCaps("[[:alpha:]]+([0-9]+)", "abc123", &.{"123"});
    try expectCaps("x|y", "z", null);
    try expectCaps("[^a]", "A", &.{});
}
