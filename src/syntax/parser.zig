//! Recursive-descent parser with precedence climbing for operators. It
//! follows the productions of Nix's `parser.y` one to one, including its
//! oddities: `or` as an application argument, `let { body = ...; }`,
//! duplicate-attribute detection at parse time, and nonassociative
//! comparison operators.
//!
//! Variable-length children are built on per-table scratch stacks and
//! moved into the `Ast` side tables in one block when their parent node is
//! complete, so a nested construct never splits its parent's run.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const Scratch = @import("../Scratch.zig");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const AttrElem = ast_mod.AttrElem;
const BinOp = ast_mod.BinOp;
const Bind = ast_mod.Bind;
const Expr = ast_mod.Expr;
const ExprId = ast_mod.ExprId;
const FileId = ast_mod.FileId;
const Formal = ast_mod.Formal;
const Name = ast_mod.Name;
const Range = ast_mod.Range;
const Span = ast_mod.Span;
const StrPart = ast_mod.StrPart;
const lexer = @import("lexer.zig");
const IndPart = lexer.IndPart;
const Lexer = lexer.Lexer;
const Tok = lexer.Tok;
const Token = lexer.Token;
const symbol = @import("symbol.zig");
const Interner = symbol.Interner;
const Sym = symbol.Sym;
const text = @import("text.zig");

pub const Error = lexer.Error;

const Assoc = enum { left, right, none };

const bp_not: u8 = 7;
const bp_neg: u8 = 12;

const OpInfo = struct { bp: u8, assoc: Assoc, op: ?BinOp };

fn binop(kind: Tok) ?OpInfo {
    return switch (kind) {
        .impl => .{ .bp = 1, .assoc = .right, .op = .impl },
        .or_or => .{ .bp = 2, .assoc = .left, .op = .@"or" },
        .and_and => .{ .bp = 3, .assoc = .left, .op = .@"and" },
        .eq => .{ .bp = 4, .assoc = .none, .op = .eq },
        .ne => .{ .bp = 4, .assoc = .none, .op = .ne },
        .lt => .{ .bp = 5, .assoc = .none, .op = .lt },
        .gt => .{ .bp = 5, .assoc = .none, .op = .gt },
        .le => .{ .bp = 5, .assoc = .none, .op = .le },
        .ge => .{ .bp = 5, .assoc = .none, .op = .ge },
        .update => .{ .bp = 6, .assoc = .right, .op = .update },
        .plus => .{ .bp = 8, .assoc = .left, .op = .add },
        .minus => .{ .bp = 8, .assoc = .left, .op = .sub },
        .star => .{ .bp = 9, .assoc = .left, .op = .mul },
        .slash => .{ .bp = 9, .assoc = .left, .op = .div },
        .concat => .{ .bp = 10, .assoc = .right, .op = .concat },
        // `%nonassoc '?'` never applies: the right side is an attribute
        // path, so `a ? b ? c` has no conflict to resolve and parses
        .question => .{ .bp = 11, .assoc = .left, .op = null },
        else => null,
    };
}

fn startsSimple(kind: Tok) bool {
    return switch (kind) {
        .id, .int, .float, .dquote, .ind_open, .path, .hpath, .spath, .uri, .l_paren, .let, .rec, .l_brace, .l_bracket => true,
        else => false,
    };
}

/// `ArrayList.append`, inline: the parser appends for nearly every token,
/// and the call LLVM left out of line cost more than the store.
fn push(gpa: Allocator, l: anytype, x: @TypeOf(l.items[0])) callconv(ast_mod.inline_release) !void {
    if (l.items.len == l.capacity) try l.ensureUnusedCapacity(gpa, 1);
    l.appendAssumeCapacity(x);
}

/// Move `stack[mark..]` to the end of `table` and describe where it went.
fn commit(comptime T: type, gpa: Allocator, table: *std.ArrayList(T), stack: *std.ArrayList(T), mark: usize) !Range {
    const start: u32 = @intCast(table.items.len);
    try table.appendSlice(gpa, stack.items[mark..]);
    stack.shrinkRetainingCapacity(mark);
    return .{ .start = start, .len = @intCast(table.items.len - start) };
}

const Formals = struct { Range, bool };

/// A parse result as it crosses a call: payload and failure in two
/// registers. Zig returns an error union through memory, and the caller's
/// one wide reload of the payload and the error code, stored separately,
/// stalls store forwarding at every level of the descent.
const Word = packed struct(u128) {
    a: u32 = 0,
    b: u32 = 0,
    failed: bool = false,
    _pad: u63 = 0,

    inline fn of(comptime T: type, x: T) Word {
        return switch (T) {
            void => .{},
            ExprId, Sym => .{ .a = @backingInt(x) },
            Range => .{ .a = x.start, .b = x.len },
            AttrElem => switch (x) {
                .static => |v| .{ .a = v.index() },
                .dynamic => |v| .{ .a = v.index(), .b = 1 },
            },
            Formals => .{ .a = x[0].start, .b = x[0].len, ._pad = @intFromBool(x[1]) },
            else => @compileError("no Word for " ++ @typeName(T)),
        };
    }

    inline fn to(w: Word, comptime T: type) T {
        return switch (T) {
            void => {},
            ExprId, Sym => @fromBackingInt(w.a),
            Range => .{ .start = w.a, .len = w.b },
            AttrElem => if (w.b == 0) .{ .static = @fromBackingInt(w.a) } else .{ .dynamic = @fromBackingInt(w.a) },
            Formals => .{ .{ .start = w.a, .len = w.b }, w._pad != 0 },
            else => @compileError("no Word for " ++ @typeName(T)),
        };
    }
};

fn Payload(comptime body: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(body)).@"fn".return_type.?).error_union.payload;
}

/// The out-of-line half of `Parser.across`: `body` inlined, its error
/// parked in `pending`.
fn Shim(comptime body: anytype) type {
    const P = @typeInfo(@TypeOf(body)).@"fn".param_types;
    const T = Payload(body);
    return switch (P.len) {
        1 => struct {
            fn run(p: *Parser) Word {
                return p.park(T, @call(.always_inline, body, .{p}));
            }
        },
        2 => struct {
            fn run(p: *Parser, a: P[1].?) Word {
                return p.park(T, @call(.always_inline, body, .{ p, a }));
            }
        },
        3 => struct {
            fn run(p: *Parser, a: P[1].?, b: P[2].?) Word {
                return p.park(T, @call(.always_inline, body, .{ p, a, b }));
            }
        },
        else => @compileError("Shim takes up to two arguments"),
    };
}

/// Nix has no limit and reports a stack overflow from its SIGSEGV handler.
/// This parser recurses, so a limit takes the place of the crash. The
/// value is a third of the deepest nesting the evaluator stack survived in
/// iets (150,000 nested attribute sets). The parse needs a large stack to
/// reach it: run it on a thread with a few hundred MiB.
pub const max_parse_depth: u32 = 50_000;

pub const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    lx: Lexer,
    tok: ?Token = null,
    next: ?Token = null,
    last_end: u32 = 0,
    interner: *Interner,
    ast: Ast,
    sc_ids: std.ArrayList(ExprId) = .empty,
    sc_elems: std.ArrayList(AttrElem) = .empty,
    sc_parts: std.ArrayList(StrPart) = .empty,
    sc_binds: std.ArrayList(Bind) = .empty,
    sc_names: std.ArrayList(Name) = .empty,
    sc_formals: std.ArrayList(Formal) = .empty,
    sc_ind: std.ArrayList(IndPart) = .empty,
    sym_or: Sym,
    sym_body: Sym,
    /// Every `''` string node, with whether Nix keeps it as a concatenation
    /// of several tokens although it is one literal part here. In id order,
    /// as the parser adds nodes.
    ind_strs: std.ArrayList(IndStr) = .empty,
    depth: u32 = 0,
    /// Runs jobs on other threads: a huge set's bindings are parsed in
    /// chunks at once (`parallelBinds`).
    par: ?*const Parallel = null,
    /// A chunked parse was tried in this file.
    par_tried: bool = false,
    /// The error of a `Word` that failed.
    pending: Error = error.SyntaxError,
    /// Scratch for the duplicate-attribute check, reset after each use.
    dup_arena: Scratch,

    const IndStr = struct { id: ExprId, concat: bool };

    /// `ast` is reused: its contents are discarded, its buffers kept. The
    /// parser owns it from here, also when `init` fails.
    pub fn init(gpa: Allocator, src: []const u8, interner: *Interner, ast: Ast, d: *Diag) !Parser {
        return initSized(gpa, src, interner, ast, d, src.len);
    }

    /// `init` with the tables sized for `n` bytes of source.
    fn initSized(gpa: Allocator, src: []const u8, interner: *Interner, ast: Ast, d: *Diag, n: usize) !Parser {
        var p: Parser = .{
            .gpa = gpa,
            .src = src,
            .lx = .init(gpa, src, d),
            .interner = interner,
            .ast = ast,
            .sym_or = undefined,
            .sym_body = undefined,
            .dup_arena = .init(gpa),
        };
        p.ast.clear();
        errdefer p.deinit();
        p.sym_or = try interner.intern("or");
        p.sym_body = try interner.intern("body");
        const cap = n / 12 + 8;
        try p.ast.ensureCapacity(gpa, cap);
        // The side tables and the scratch stacks at about twice their mean
        // size per source byte (nixos-server's files): grown by doubling,
        // each step copied a table the parse had long left, from memory.
        inline for (.{
            .{ &p.ast.ids, 36 },  .{ &p.ast.elems, 26 },   .{ &p.ast.parts, 60 },
            .{ &p.ast.bytes, 2 }, .{ &p.ast.binds, 40 },   .{ &p.ast.formals, 86 },
            .{ &p.sc_ids, 72 },   .{ &p.sc_elems, 52 },    .{ &p.sc_parts, 120 },
            .{ &p.sc_binds, 80 }, .{ &p.sc_formals, 172 },
        }) |t| try t[0].ensureTotalCapacity(gpa, n / t[1] + 8);
        return p;
    }

    /// Frees the scratch; the `Ast` is freed too unless `parseFile` handed
    /// it out.
    pub fn deinit(p: *Parser) void {
        p.lx.deinit();
        inline for (.{ "sc_ids", "sc_elems", "sc_parts", "sc_binds", "sc_names", "sc_formals", "sc_ind", "ind_strs" }) |f|
            @field(p, f).deinit(p.gpa);
        p.dup_arena.deinit();
        p.ast.deinit(p.gpa);
    }

    /// The byte offset of the error after `parseFile` failed with
    /// `error.SyntaxError`; the message is in the `Diag`.
    pub fn errorOffset(p: *const Parser) u32 {
        return p.lx.err_at;
    }

    /// Parse the whole file. On success the `Ast` moves to the caller (who
    /// frees it); `deinit` must still be called.
    pub fn parseFile(p: *Parser, file: FileId) Error!Ast {
        const root = try p.parseExpr();
        const t = p.peek();
        if (t.kind != .eof) return p.unexpected(t, "expecting end of file");
        try p.lx.takeAllows(&p.ast.allows, p.gpa);
        p.ast.file = file;
        p.ast.root = root;
        const a = p.ast;
        p.ast = .{};
        return a;
    }

    /// `body(p, args...)` behind a real call that returns in registers
    /// (`Word`); `try` at the call site stays as it is. Debug builds call
    /// `body` directly: the deep-nesting limit is sized for one frame per
    /// level.
    fn across(p: *Parser, comptime body: anytype, args: anytype) callconv(ast_mod.inline_release) Error!Payload(body) {
        if (builtin.mode == .debug) return @call(.auto, body, .{p} ++ args);
        const w = @call(.never_inline, Shim(body).run, .{p} ++ args);
        if (w.failed) return p.pending;
        return w.to(Payload(body));
    }

    inline fn park(p: *Parser, comptime T: type, r: Error!T) Word {
        const x = r catch |e| {
            p.pending = e;
            return .{ .failed = true };
        };
        return .of(T, x);
    }

    fn fail(p: *Parser, at: u32, comptime fmt: []const u8, args: anytype) error{SyntaxError} {
        return p.lx.fail(at, fmt, args);
    }

    fn unexpected(p: *Parser, t: Token, comptime expecting: ?[]const u8) error{SyntaxError} {
        if (expecting) |e| return p.fail(t.start, "syntax error, unexpected {s}, {s}", .{ t.kind.describe(), e });
        return p.fail(t.start, "syntax error, unexpected {s}", .{t.kind.describe()});
    }

    /// One more level of nesting, or Nix's stack-overflow error.
    inline fn deeper(p: *Parser) error{SyntaxError}!void {
        p.depth += 1;
        if (p.depth > max_parse_depth) {
            const t = p.peek();
            return p.fail(t.start, "stack overflow (possible infinite recursion)", .{});
        }
    }

    inline fn peek(p: *Parser) Token {
        if (p.tok) |t| return t;
        const t = if (p.next) |n| n else p.lx.nextToken();
        p.next = null;
        p.tok = t;
        return t;
    }

    fn peek2(p: *Parser) Token {
        _ = p.peek();
        if (p.next) |n| return n;
        const t = p.lx.nextToken();
        p.next = t;
        return t;
    }

    /// Third token of lookahead. Only valid right after `peek2`.
    fn peek3(p: *Parser) Token {
        const save = p.lx.pos;
        const t = p.lx.nextToken();
        p.lx.pos = save;
        return t;
    }

    inline fn bump(p: *Parser) Token {
        const t = p.peek();
        p.tok = null;
        p.last_end = t.end;
        return t;
    }

    fn expect(p: *Parser, kind: Tok, comptime expecting: []const u8) callconv(ast_mod.inline_release) error{SyntaxError}!Token {
        const t = p.peek();
        if (t.kind == kind) return p.bump();
        return p.unexpected(t, expecting);
    }

    fn add(p: *Parser, e: Expr, start: u32, end: u32) callconv(ast_mod.inline_release) !ExprId {
        return p.ast.add(p.gpa, e, .{ .start = start, .end = end });
    }

    fn textOf(p: *const Parser, t: Token) []const u8 {
        return p.src[t.start..t.end];
    }

    fn intern(p: *Parser, b: []const u8) callconv(ast_mod.inline_release) Error!Sym {
        return p.across(internBody, .{b});
    }

    fn internBody(p: *Parser, b: []const u8) Error!Sym {
        return p.interner.intern(b);
    }

    /// Store `b` in the bytes table.
    fn lit(p: *Parser, b: []const u8) !StrPart {
        const start: u32 = @intCast(p.ast.bytes.items.len);
        try p.ast.bytes.appendSlice(p.gpa, b);
        return .{ .lit = .{ .start = start, .len = @intCast(b.len) } };
    }

    /// One-part string over `b`.
    fn singleStr(p: *Parser, b: []const u8) callconv(ast_mod.inline_release) Error!Range {
        return p.across(singleStrBody, .{b});
    }

    fn singleStrBody(p: *Parser, b: []const u8) Error!Range {
        const mark = p.sc_parts.items.len;
        try push(p.gpa, &p.sc_parts, try p.lit(b));
        return commit(StrPart, p.gpa, &p.ast.parts, &p.sc_parts, mark);
    }

    fn oneId(p: *Parser, id: ExprId) callconv(ast_mod.inline_release) Error!Range {
        return p.across(oneIdBody, .{id});
    }

    fn oneIdBody(p: *Parser, id: ExprId) Error!Range {
        const mark = p.sc_ids.items.len;
        try push(p.gpa, &p.sc_ids, id);
        return commit(ExprId, p.gpa, &p.ast.ids, &p.sc_ids, mark);
    }

    pub fn parseExpr(p: *Parser) Error!ExprId {
        return p.parseFunction();
    }

    fn parseFunction(p: *Parser) callconv(ast_mod.inline_release) Error!ExprId {
        return p.across(parseFunctionBody, .{});
    }

    fn parseFunctionBody(p: *Parser) Error!ExprId {
        try p.deeper();
        defer p.depth -= 1;
        return p.parseFunctionInner();
    }

    fn lambdaPattern(p: *Parser, bind: ?Sym, formals: Range, ellipsis: bool, body: ExprId, start: u32) !ExprId {
        const i: u32 = @intCast(p.ast.patterns.items.len);
        try push(p.gpa, &p.ast.patterns, .{ .bind = bind, .formals = formals, .ellipsis = ellipsis });
        return p.add(.{ .lambda_pattern = .{ .pattern = i, .body = body } }, start, p.last_end);
    }

    fn parseFunctionInner(p: *Parser) Error!ExprId {
        const t = p.peek();
        switch (t.kind) {
            .id => {
                const n = p.peek2();
                switch (n.kind) {
                    .colon => {
                        _ = p.bump();
                        _ = p.bump();
                        const name = try p.intern(p.textOf(t));
                        const body = try p.parseFunction();
                        return p.add(.{ .lambda = .{ .arg = name, .body = body } }, t.start, p.last_end);
                    },
                    .at => {
                        _ = p.bump();
                        _ = p.bump();
                        const name = try p.intern(p.textOf(t));
                        const formals, const ellipsis = try p.parseFormals();
                        _ = try p.expect(.colon, "expecting ':'");
                        const body = try p.parseFunction();
                        try p.validateFormals(formals, name, t.span());
                        return p.lambdaPattern(name, formals, ellipsis, body, t.start);
                    },
                    else => return p.parseIf(),
                }
            },
            .l_brace => {
                if (!p.isFormals()) return p.parseIf();
                const formals, const ellipsis = try p.parseFormals();
                var bind: ?Sym = null;
                if (p.peek().kind == .at) {
                    _ = p.bump();
                    const n = try p.expect(.id, "expecting identifier");
                    bind = try p.intern(p.textOf(n));
                }
                _ = try p.expect(.colon, "expecting ':'");
                // parser.y validates the formals once the body is parsed,
                // and reports a clash with the `@` name at the rule's start
                const body = try p.parseFunction();
                try p.validateFormals(formals, bind, t.span());
                return p.lambdaPattern(bind, formals, ellipsis, body, t.start);
            },
            .assert => {
                _ = p.bump();
                const cond = try p.parseExpr();
                _ = try p.expect(.semi, "expecting ';'");
                const body = try p.parseFunction();
                return p.add(.{ .assert = .{ .cond = cond, .body = body } }, t.start, p.last_end);
            },
            .with => {
                _ = p.bump();
                const scope = try p.parseExpr();
                _ = try p.expect(.semi, "expecting ';'");
                const body = try p.parseFunction();
                return p.add(.{ .with = .{ .scope = scope, .body = body } }, t.start, p.last_end);
            },
            .let => {
                if (p.peek2().kind == .l_brace) return p.parseIf();
                _ = p.bump();
                const binds = try p.parseBinds(.in);
                _ = try p.expect(.in, "expecting 'in'");
                const body = try p.parseFunction();
                // parser.y checks once the body is parsed, at the `let`
                for (p.ast.bindsOf(binds)) |b| switch (b.kind) {
                    .value => |v| if (p.ast.elemsOf(v.path)[0] == .dynamic)
                        return p.fail(t.start, "dynamic attributes not allowed in let", .{}),
                    .inherit => {},
                };
                return p.add(.{ .let = .{ .binds = binds, .body = body } }, t.start, p.last_end);
            },
            else => return p.parseIf(),
        }
    }

    /// Decide between a formals pattern and an attrset after `{`.
    fn isFormals(p: *Parser) bool {
        const n = p.peek2();
        return switch (n.kind) {
            .ellipsis => true,
            .r_brace => switch (p.peek3().kind) {
                .colon, .at => true,
                else => false,
            },
            .id => switch (p.peek3().kind) {
                .comma, .question, .r_brace => true,
                else => false,
            },
            else => false,
        };
    }

    fn parseFormals(p: *Parser) callconv(ast_mod.inline_release) Error!Formals {
        return p.across(parseFormalsBody, .{});
    }

    fn parseFormalsBody(p: *Parser) Error!Formals {
        _ = try p.expect(.l_brace, "expecting '{'");
        const mark = p.sc_formals.items.len;
        var ellipsis = false;
        loop: while (true) {
            const t = p.peek();
            switch (t.kind) {
                .r_brace => {
                    _ = p.bump();
                    break;
                },
                .ellipsis => {
                    _ = p.bump();
                    ellipsis = true;
                    _ = try p.expect(.r_brace, "expecting '}'");
                    break;
                },
                .id => {
                    _ = p.bump();
                    const name = try p.intern(p.textOf(t));
                    var default: ExprId = .none;
                    if (p.peek().kind == .question) {
                        _ = p.bump();
                        default = try p.parseExpr();
                    }
                    try push(p.gpa, &p.sc_formals, .{
                        .name = name,
                        .default = default,
                        .span = .{ .start = t.start, .end = p.last_end },
                    });
                    const n = p.peek();
                    switch (n.kind) {
                        .comma => _ = p.bump(),
                        .r_brace => {
                            _ = p.bump();
                            break :loop;
                        },
                        else => return p.unexpected(n, "expecting '}' or ','"),
                    }
                },
                else => return p.unexpected(t, "expecting identifier or '...' or '}'"),
            }
        }
        const r = try commit(Formal, p.gpa, &p.ast.formals, &p.sc_formals, mark);
        return .{ r, ellipsis };
    }

    fn validateFormals(p: *Parser, range: Range, bind: ?Sym, bind_span: Span) Error!void {
        const formals = p.ast.formalsOf(range);
        if (formals.len > 1 and !formalsDistinct(formals)) {
            // (name, start) pairs as one integer each, sorted: the first
            // clash in name-id order, at its later occurrence, as Rust iets
            // reports it
            var buf: [64]u64 = undefined;
            const heap = formals.len > buf.len;
            const seen = if (heap) try p.gpa.alloc(u64, formals.len) else buf[0..formals.len];
            defer if (heap) p.gpa.free(seen);
            for (formals, seen) |f, *x| x.* = @as(u64, f.name.index()) << 32 | f.span.start;
            std.mem.sortUnstable(u64, seen, {}, std.sort.asc(u64));
            for (seen[0 .. seen.len - 1], seen[1..]) |x, y| {
                if (x >> 32 != y >> 32) continue;
                const start: u32 = @truncate(y);
                for (formals) |f| if (f.span.start == start)
                    return p.fail(f.span.start, "duplicate formal function argument '{s}'", .{p.interner.nameStr(f.name)});
                unreachable;
            }
        }
        if (bind) |b| for (formals) |f| if (f.name == b)
            return p.fail(bind_span.start, "duplicate formal function argument '{s}'", .{p.interner.nameStr(b)});
    }

    fn parseIf(p: *Parser) callconv(ast_mod.inline_release) Error!ExprId {
        return p.across(parseIfBody, .{});
    }

    fn parseIfBody(p: *Parser) Error!ExprId {
        const t = p.peek();
        if (t.kind == .@"if") {
            _ = p.bump();
            const cond = try p.parseExpr();
            _ = try p.expect(.then, "expecting 'then'");
            const then = try p.parseExpr();
            _ = try p.expect(.@"else", "expecting 'else'");
            const else_ = try p.parseExpr();
            return p.add(.{ .@"if" = .{ .cond = cond, .then = then, .@"else" = else_ } }, t.start, p.last_end);
        }
        return p.parsePipe();
    }

    /// Mixing `|>` and `<|` is not refused here: bison reduces up through
    /// the enclosing rules first (running their checks, such as the
    /// duplicate formals of a lambda) and fails where the enclosing rule
    /// meets the operator, which is where this parser's caller does too.
    fn parsePipe(p: *Parser) Error!ExprId {
        const lhs = try p.parseOp(0);
        switch (p.peek().kind) {
            .pipe_into => {
                var acc = lhs;
                while (p.peek().kind == .pipe_into) {
                    _ = p.bump();
                    const f = try p.parseOp(0);
                    acc = try p.makeCall(f, acc);
                }
                return acc;
            },
            .pipe_from => {
                const mark = p.sc_ids.items.len;
                defer p.sc_ids.shrinkRetainingCapacity(mark);
                try push(p.gpa, &p.sc_ids, lhs);
                while (p.peek().kind == .pipe_from) {
                    _ = p.bump();
                    const e = try p.parseOp(0);
                    try push(p.gpa, &p.sc_ids, e);
                }
                var acc = p.sc_ids.pop().?;
                while (p.sc_ids.items.len > mark) acc = try p.makeCall(p.sc_ids.pop().?, acc);
                return acc;
            },
            else => return lhs,
        }
    }

    /// `f a` becomes one `apply`; applying an `apply` again extends it,
    /// exactly like Nix's `makeCall`. The extended argument run is copied
    /// to the end of the table; the old run is left behind.
    fn makeCall(p: *Parser, func: ExprId, arg: ExprId) callconv(ast_mod.inline_release) Error!ExprId {
        return p.across(makeCallBody, .{ func, arg });
    }

    fn makeCallBody(p: *Parser, func: ExprId, arg: ExprId) Error!ExprId {
        const arg_span = p.ast.span(arg);
        switch (p.ast.expr(func)) {
            .apply => |ap| {
                const mark = p.sc_ids.items.len;
                try p.sc_ids.appendSlice(p.gpa, p.ast.idsOf(ap.args));
                try push(p.gpa, &p.sc_ids, arg);
                const args = try commit(ExprId, p.gpa, &p.ast.ids, &p.sc_ids, mark);
                p.ast.set(func, .{ .apply = .{ .func = ap.func, .args = args } });
                const s = &p.ast.spans.items[func.index()];
                s.start = @min(s.start, arg_span.start);
                s.end = @max(s.end, arg_span.end);
                return func;
            },
            else => {
                const fs = p.ast.span(func);
                const args = try p.oneId(arg);
                return p.add(.{ .apply = .{ .func = func, .args = args } }, @min(fs.start, arg_span.start), @max(fs.end, arg_span.end));
            },
        }
    }

    fn parseOp(p: *Parser, min_bp: u8) callconv(ast_mod.inline_release) Error!ExprId {
        return p.across(parseOpBody, .{min_bp});
    }

    fn parseOpBody(p: *Parser, min_bp: u8) Error!ExprId {
        const t = p.peek();
        var lhs: ExprId = switch (t.kind) {
            .bang => blk: {
                _ = p.bump();
                try p.deeper();
                const e = try p.parseOp(bp_not + 1);
                p.depth -= 1;
                break :blk try p.add(.{ .unary = .{ .op = .not, .expr = e } }, t.start, p.last_end);
            },
            .minus => blk: {
                _ = p.bump();
                try p.deeper();
                const e = try p.parseOp(bp_neg + 1);
                p.depth -= 1;
                switch (p.ast.expr(e)) {
                    .int => |i| {
                        p.ast.set(e, .{ .int = 0 -% i });
                        p.ast.spans.items[e.index()].start = t.start;
                        break :blk e;
                    },
                    .float => |f| {
                        p.ast.set(e, .{ .float = 0.0 - f });
                        p.ast.spans.items[e.index()].start = t.start;
                        break :blk e;
                    },
                    else => break :blk try p.add(.{ .unary = .{ .op = .neg, .expr = e } }, t.start, p.last_end),
                }
            },
            else => try p.parseApp(),
        };
        while (true) {
            const op = p.peek();
            const info = binop(op.kind) orelse break;
            if (info.bp < min_bp) break;
            _ = p.bump();
            const start = p.ast.span(lhs).start;
            if (info.op) |bin| {
                const rhs = try p.parseOp(if (info.assoc == .right) info.bp else info.bp + 1);
                lhs = try p.add(.{ .binary = .{ .op = bin, .lhs = lhs, .rhs = rhs } }, start, p.last_end);
            } else {
                const path = try p.parseAttrpath();
                lhs = try p.add(.{ .has_attr = .{ .subject = lhs, .path = path } }, start, p.last_end);
            }
            if (info.assoc == .none) {
                const n = p.peek();
                if (binop(n.kind)) |next_info| if (next_info.bp == info.bp) return p.unexpected(n, null);
            }
        }
        return lhs;
    }

    /// `f a b c`: the arguments are collected first so they land in one
    /// run; a `func` that already is an `apply` (the `or` argument hack) is
    /// extended like `makeCall` does.
    fn parseApp(p: *Parser) Error!ExprId {
        const f = try p.parseSelect();
        if (!startsSimple(p.peek().kind)) return f;
        const mark = p.sc_ids.items.len;
        const existing: ?ExprId = switch (p.ast.expr(f)) {
            .apply => |ap| blk: {
                try p.sc_ids.appendSlice(p.gpa, p.ast.idsOf(ap.args));
                break :blk ap.func;
            },
            else => null,
        };
        while (startsSimple(p.peek().kind)) {
            const a = try p.parseSelect();
            try push(p.gpa, &p.sc_ids, a);
        }
        const args = try commit(ExprId, p.gpa, &p.ast.ids, &p.sc_ids, mark);
        const last = p.ast.idsOf(args)[args.len - 1];
        const end = p.ast.span(last).end;
        if (existing) |func| {
            p.ast.set(f, .{ .apply = .{ .func = func, .args = args } });
            const s = &p.ast.spans.items[f.index()];
            s.end = @max(s.end, end);
            return f;
        }
        const fs = p.ast.span(f);
        return p.add(.{ .apply = .{ .func = f, .args = args } }, fs.start, @max(fs.end, end));
    }

    fn parseSelect(p: *Parser) callconv(ast_mod.inline_release) Error!ExprId {
        return p.across(parseSelectBody, .{});
    }

    fn parseSelectBody(p: *Parser) Error!ExprId {
        const start = p.peek().start;
        const subject = try p.parseSimple();
        switch (p.peek().kind) {
            .dot => {
                _ = p.bump();
                const path = try p.parseAttrpath();
                var default: ExprId = .none;
                if (p.peek().kind == .@"or") {
                    _ = p.bump();
                    default = try p.parseSelect();
                }
                return p.add(.{ .select = .{ .subject = subject, .path = path, .default = default } }, start, p.last_end);
            },
            .@"or" => {
                const t = p.bump();
                const o = try p.add(.{ .@"var" = p.sym_or }, t.start, t.end);
                const args = try p.oneId(o);
                return p.add(.{ .apply = .{ .func = subject, .args = args } }, start, t.end);
            },
            else => return subject,
        }
    }

    fn parseSimple(p: *Parser) callconv(ast_mod.inline_release) Error!ExprId {
        return p.across(parseSimpleBody, .{});
    }

    fn parseSimpleBody(p: *Parser) Error!ExprId {
        try p.deeper();
        defer p.depth -= 1;
        return p.parseSimpleInner();
    }

    fn parseSimpleInner(p: *Parser) Error!ExprId {
        const t = p.peek();
        switch (t.kind) {
            .id => {
                _ = p.bump();
                const s = try p.intern(p.textOf(t));
                return p.add(.{ .@"var" = s }, t.start, t.end);
            },
            .int => {
                _ = p.bump();
                const txt = p.textOf(t);
                const v = parseInt(txt) orelse
                    return p.fail(t.start, "invalid integer '{f}'", .{text.lossy(txt)});
                return p.add(.{ .int = v }, t.start, t.end);
            },
            .float => {
                _ = p.bump();
                const txt = p.textOf(t);
                const v = std.fmt.parseFloat(f64, txt) catch std.math.inf(f64);
                // lexer.l reports every strtod ERANGE, so an overflow, a
                // subnormal and an underflow to zero are all invalid
                const mantissa = txt[0 .. std.mem.findAny(u8, txt, "eE") orelse txt.len];
                const nonzero_digit = std.mem.findNone(u8, mantissa, "0.") != null;
                const range = !std.math.isFinite(v) or
                    (v != 0 and @abs(v) < std.math.floatMin(f64)) or
                    (v == 0 and nonzero_digit);
                if (range) return p.fail(t.start, "invalid float '{s}'", .{txt});
                return p.add(.{ .float = v }, t.start, t.end);
            },
            .dquote => {
                _ = p.bump();
                const parts = try p.parseStringParts();
                return p.add(.{ .str = parts }, t.start, p.last_end);
            },
            .ind_open => {
                _ = p.bump();
                const parts, const pieces = try p.parseIndString();
                const e = try p.add(.{ .str = parts }, t.start, p.last_end);
                const concat = pieces > 1 and p.ast.singleLit(parts) != null;
                try push(p.gpa, &p.ind_strs, .{ .id = e, .concat = concat });
                return e;
            },
            .path, .hpath => {
                _ = p.bump();
                return p.parsePath(t);
            },
            .spath => {
                _ = p.bump();
                const txt = p.textOf(t);
                const parts = try p.singleStr(txt[1 .. txt.len - 1]);
                return p.add(.{ .path = .{ .kind = .search, .parts = parts } }, t.start, t.end);
            },
            .uri => {
                _ = p.bump();
                const parts = try p.singleStr(p.textOf(t));
                const id = try p.add(.{ .str = parts }, t.start, t.end);
                try push(p.gpa, &p.ast.notes, .{ .url = id });
                return id;
            },
            .l_paren => {
                _ = p.bump();
                const e = try p.parseExpr();
                _ = try p.expect(.r_paren, "expecting ')'");
                return e;
            },
            .let => {
                _ = p.bump();
                _ = try p.expect(.l_brace, "expecting '{'");
                const binds = try p.parseBinds(.r_brace);
                _ = try p.expect(.r_brace, "expecting '}'");
                const attrs = try p.add(.{ .attrs = .{ .rec = true, .binds = binds } }, t.start, p.last_end);
                const mark = p.sc_elems.items.len;
                try push(p.gpa, &p.sc_elems, .{ .static = p.sym_body });
                const path = try commit(AttrElem, p.gpa, &p.ast.elems, &p.sc_elems, mark);
                return p.add(.{ .select = .{ .subject = attrs, .path = path, .default = .none } }, t.start, p.last_end);
            },
            .rec, .l_brace => {
                _ = p.bump();
                const rec = t.kind == .rec;
                if (rec) _ = try p.expect(.l_brace, "expecting '{'");
                const binds = try p.parseBinds(.r_brace);
                _ = try p.expect(.r_brace, "expecting '}'");
                return p.add(.{ .attrs = .{ .rec = rec, .binds = binds } }, t.start, p.last_end);
            },
            .l_bracket => {
                _ = p.bump();
                const mark = p.sc_ids.items.len;
                while (true) {
                    const n = p.peek();
                    if (n.kind == .r_bracket) {
                        _ = p.bump();
                        break;
                    }
                    if (!startsSimple(n.kind)) return p.unexpected(n, null);
                    const e = try p.parseSelect();
                    try push(p.gpa, &p.sc_ids, e);
                }
                const items = try commit(ExprId, p.gpa, &p.ast.ids, &p.sc_ids, mark);
                return p.add(.{ .list = items }, t.start, p.last_end);
            },
            else => return p.unexpected(t, null),
        }
    }

    /// Body of a `"..."` string; the opening quote is already consumed.
    /// Literal chunks are decoded straight into the bytes table.
    fn parseStringParts(p: *Parser) callconv(ast_mod.inline_release) Error!Range {
        return p.across(parseStringPartsBody, .{});
    }

    fn parseStringPartsBody(p: *Parser) Error!Range {
        std.debug.assert(p.tok == null and p.next == null);
        const mark = p.sc_parts.items.len;
        while (true) {
            const start = p.ast.bytes.items.len;
            const end = try p.lx.lexStrChunk(&p.ast.bytes, p.gpa);
            const n = p.ast.bytes.items.len - start;
            const l: StrPart = .{ .lit = .{ .start = @intCast(start), .len = @intCast(n) } };
            switch (end) {
                .close => {
                    if (n != 0 or p.sc_parts.items.len == mark) try push(p.gpa, &p.sc_parts, l);
                    p.last_end = @intCast(p.lx.pos);
                    return commit(StrPart, p.gpa, &p.ast.parts, &p.sc_parts, mark);
                },
                .interp => {
                    if (n != 0) try push(p.gpa, &p.sc_parts, l);
                    const e = try p.parseExpr();
                    _ = try p.expect(.r_brace, "expecting '}'");
                    try push(p.gpa, &p.sc_parts, .{ .interp = e });
                },
            }
        }
    }

    /// The parts, and how many pieces Nix's `stripIndentation` keeps.
    fn parseIndString(p: *Parser) Error!struct { Range, usize } {
        std.debug.assert(p.tok == null and p.next == null);
        const ind_mark = p.sc_ind.items.len;
        const ids_mark = p.sc_ids.items.len;
        defer p.sc_ind.shrinkRetainingCapacity(ind_mark);
        defer p.sc_ids.shrinkRetainingCapacity(ids_mark);
        while (true) {
            switch (try p.lx.lexIndChunk(&p.sc_ind, p.gpa)) {
                .close => break,
                .interp => {
                    const e = try p.parseExpr();
                    _ = try p.expect(.r_brace, "expecting '}'");
                    try push(p.gpa, &p.sc_ind, .interp);
                    try push(p.gpa, &p.sc_ids, e);
                },
            }
        }
        p.last_end = @intCast(p.lx.pos);
        const mark = p.sc_parts.items.len;
        const pieces = try stripIndentation(
            p.gpa,
            p.src,
            p.sc_ind.items[ind_mark..],
            p.sc_ids.items[ids_mark..],
            &p.ast.bytes,
            &p.sc_parts,
        );
        return .{ try commit(StrPart, p.gpa, &p.ast.parts, &p.sc_parts, mark), pieces };
    }

    fn parsePath(p: *Parser, t: Token) Error!ExprId {
        const txt = p.textOf(t);
        const kind: ast_mod.PathKind, const first = if (t.kind == .hpath)
            .{ .home, txt[1..] }
        else if (txt[0] == '/')
            .{ .absolute, txt }
        else
            .{ .relative, txt };
        const mark = p.sc_parts.items.len;
        try push(p.gpa, &p.sc_parts, try p.lit(first));
        var after_slash = txt[txt.len - 1] == '/';
        // parser.y: `string_parts_interpolated` begins with `${` or with
        // one STR that `${` follows, so a piece of text before the first
        // interpolation cannot end the path
        var need_interp = false;
        var seen_interp = false;
        var last_token = t.start;
        while (true) {
            const part = p.lx.lexPathPart(after_slash) catch |e| {
                if (p.lx.err_at == p.src.len) p.lx.err_at = last_token;
                return e;
            };
            if (part == .end and p.lx.pos == p.src.len) p.lx.eof_at = last_token;
            if (need_interp and part != .interp) {
                const what = if (part == .end) "end of path" else "string";
                // the end of a path is at its last token, but at the end of
                // the file Nix unstashes the token before it: here the first
                const at: u32 = switch (part) {
                    .str => |s| s.start,
                    else => if (p.lx.pos == p.src.len) t.start else last_token,
                };
                return p.fail(at, "syntax error, unexpected {s}, expecting '${{'", .{what});
            }
            switch (part) {
                .end => break,
                .str => |s| {
                    need_interp = !seen_interp;
                    last_token = s.start;
                    const bytes = p.src[s.start..s.end];
                    after_slash = bytes[bytes.len - 1] == '/';
                    // Consecutive literal pieces sit at the end of the bytes
                    // table (no interpolation was parsed between them), so
                    // the last part just grows.
                    const items = p.sc_parts.items;
                    if (items.len > mark and items[items.len - 1] == .lit and
                        items[items.len - 1].lit.end() == p.ast.bytes.items.len)
                    {
                        try p.ast.bytes.appendSlice(p.gpa, bytes);
                        items[items.len - 1].lit.len += @intCast(bytes.len);
                    } else {
                        try push(p.gpa, &p.sc_parts, try p.lit(bytes));
                    }
                    p.last_end = s.end;
                },
                .interp => {
                    need_interp = false;
                    seen_interp = true;
                    const e = try p.parseExpr();
                    last_token = (try p.expect(.r_brace, "expecting '}'")).start;
                    try push(p.gpa, &p.sc_parts, .{ .interp = e });
                    after_slash = false;
                },
            }
        }
        const parts = try commit(StrPart, p.gpa, &p.ast.parts, &p.sc_parts, mark);
        return p.add(.{ .path = .{ .kind = kind, .parts = parts } }, t.start, p.last_end);
    }

    fn parseAttrpath(p: *Parser) callconv(ast_mod.inline_release) Error!Range {
        return p.across(parseAttrpathBody, .{});
    }

    fn parseAttrpathBody(p: *Parser) Error!Range {
        const mark = p.sc_elems.items.len;
        while (true) {
            const e = try p.parseAttrElem();
            try push(p.gpa, &p.sc_elems, e);
            if (p.peek().kind != .dot) return commit(AttrElem, p.gpa, &p.ast.elems, &p.sc_elems, mark);
            _ = p.bump();
        }
    }

    fn parseAttrElem(p: *Parser) Error!AttrElem {
        const t = p.peek();
        switch (t.kind) {
            .id => {
                _ = p.bump();
                return .{ .static = try p.intern(p.textOf(t)) };
            },
            .@"or" => {
                _ = p.bump();
                return .{ .static = p.sym_or };
            },
            .dquote => {
                _ = p.bump();
                const parts = try p.parseStringParts();
                return p.strToAttrElem(parts, t.start);
            },
            .dollar_curly => {
                _ = p.bump();
                const e = try p.parseExpr();
                _ = try p.expect(.r_brace, "expecting '}'");
                return p.exprToAttrElem(e);
            },
            else => return p.unexpected(t, "expecting identifier or 'or' or '${' or '\"'"),
        }
    }

    fn strToAttrElem(p: *Parser, parts: Range, start: u32) callconv(ast_mod.inline_release) Error!AttrElem {
        return p.across(strToAttrElemBody, .{ parts, start });
    }

    fn strToAttrElemBody(p: *Parser, parts: Range, start: u32) Error!AttrElem {
        const ps = p.ast.partsOf(parts);
        if (ps.len == 0) return .{ .static = try p.intern("") };
        if (ps.len == 1 and ps[0] == .lit) return .{ .static = try p.intern(p.ast.bytesOf(ps[0].lit)) };
        return .{ .dynamic = try p.add(.{ .str = parts }, start, p.last_end) };
    }

    /// `${e}` is a static attribute when Nix's tree for `e` is one
    /// `ExprString` (parser-state.hh, `StringToken::visit`).
    fn exprToAttrElem(p: *Parser, e: ExprId) Error!AttrElem {
        if (p.nixString(e)) |r| return .{ .static = try p.intern(p.ast.bytesOf(r)) };
        return .{ .dynamic = e };
    }

    /// The text of `e` when Nix parses it to one `ExprString`: a plain
    /// string, or a `''` string that `stripIndentation` leaves as one piece.
    fn nixString(p: *const Parser, e: ExprId) ?Range {
        const parts = switch (p.ast.expr(e)) {
            .str => |r| r,
            else => return null,
        };
        var ind = false;
        const Ctx = struct {
            fn cmp(key: u32, x: IndStr) std.math.Order {
                return std.math.order(key, x.id.index());
            }
        };
        if (std.sort.binarySearch(IndStr, p.ind_strs.items, e.index(), Ctx.cmp)) |i| {
            if (p.ind_strs.items[i].concat) return null;
            ind = true;
        }
        const ps = p.ast.partsOf(parts);
        if (ps.len == 0) return Range.empty;
        if (ps.len != 1) return null;
        return switch (ps[0]) {
            .lit => |l| l,
            .interp => |i| if (ind) p.nixString(i) else null,
        };
    }

    fn parseBinds(p: *Parser, closer: Tok) Error!Range {
        const mark = p.sc_binds.items.len;
        const r = p.parseBindsUntil(closer);
        const binds = try commit(Bind, p.gpa, &p.ast.binds, &p.sc_binds, mark);
        // Nix adds a binding to its set when the binding's `;` is read, so
        // a clash among the complete bindings comes before a later error
        try p.checkDupAttrs(binds);
        try r;
        return binds;
    }

    fn parseBindsUntil(p: *Parser, closer: Tok) callconv(ast_mod.inline_release) Error!void {
        return p.across(parseBindsUntilBody, .{closer});
    }

    fn parseBindsUntilBody(p: *Parser, closer: Tok) Error!void {
        if (closer == .r_brace and !p.par_tried) if (p.par) |par| {
            const at = if (p.tok) |t| t.start else if (p.next) |t| t.start else p.lx.pos;
            if (p.src.len - at > chunked_min) {
                p.par_tried = true;
                try p.parallelBinds(par, @intCast(at));
            }
        };
        while (true) {
            const t = p.peek();
            if (t.kind == closer) break;
            if (t.kind == .inherit) {
                _ = p.bump();
                var from: ExprId = .none;
                if (p.peek().kind == .l_paren) {
                    _ = p.bump();
                    from = try p.parseExpr();
                    _ = try p.expect(.r_paren, "expecting ')'");
                }
                const nmark = p.sc_names.items.len;
                names: while (true) {
                    const n = p.peek();
                    const s: Sym = switch (n.kind) {
                        .id => blk: {
                            _ = p.bump();
                            break :blk try p.intern(p.textOf(n));
                        },
                        .@"or" => blk: {
                            _ = p.bump();
                            break :blk p.sym_or;
                        },
                        .dquote => blk: {
                            _ = p.bump();
                            const parts = try p.parseStringParts();
                            const elem = try p.strToAttrElem(parts, n.start);
                            break :blk try p.staticInheritName(elem, n);
                        },
                        .dollar_curly => blk: {
                            _ = p.bump();
                            const e = try p.parseExpr();
                            _ = try p.expect(.r_brace, "expecting '}'");
                            const elem = try p.exprToAttrElem(e);
                            break :blk try p.staticInheritName(elem, n);
                        },
                        .semi => {
                            _ = p.bump();
                            break :names;
                        },
                        else => return p.unexpected(n, null),
                    };
                    try push(p.gpa, &p.sc_names, .{ .sym = s, .span = n.span() });
                }
                const names = try commit(Name, p.gpa, &p.ast.names, &p.sc_names, nmark);
                try push(p.gpa, &p.sc_binds, .{
                    .span = .{ .start = t.start, .end = p.last_end },
                    .kind = .{ .inherit = .{ .from = from, .names = names } },
                });
                continue;
            }
            const path = try p.parseAttrpath();
            _ = try p.expect(.assign, "expecting '.' or '='");
            const value = try p.parseExpr();
            _ = try p.expect(.semi, "expecting ';'");
            try push(p.gpa, &p.sc_binds, .{
                .span = .{ .start = t.start, .end = p.last_end },
                .kind = .{ .value = .{ .path = path, .value = value } },
            });
        }
    }

    /// The bindings of a huge set from `start` on, parsed in chunks by
    /// other threads, then moved into this parser's tree as the
    /// sequential parse would have made them; this parser goes on from
    /// the end of the last chunk. Chunks begin at lines indented like the
    /// first binding after a line that ends in `;`: a guess, which holds
    /// only when every chunk parses as a sequence of complete bindings up
    /// to its end exactly. If any does not, nothing is kept and the parse
    /// goes on sequentially, so errors are the sequential ones.
    fn parallelBinds(p: *Parser, par: *const Parallel, start: u32) Error!void {
        var bounds: [max_chunks + 1]u32 = undefined;
        const n = chunkBounds(p.src, start, @min(max_chunks, @max(2, par.workers * 3)), &bounds) orelse return;
        var chunks: [max_chunks]Chunk = undefined;
        for (chunks[0..n], 0..) |*c, i| c.* = .{ .start = bounds[i], .end = bounds[i + 1] };
        defer for (chunks[0..n]) |*c| c.deinit(p.gpa);
        var job: ChunkJob = .{ .p = p, .chunks = chunks[0..n], .phase = .parse };
        p.interner = par.run(par.ctx, @intCast(n), &job, ChunkJob.run);
        for (chunks[0..n]) |*c| if (!c.ok) return;

        // Every table grows once by the chunks' sizes; each chunk then
        // moves its part into place, relocated, at once with the others.
        var off: Offsets = .of(p);
        for (chunks[0..n]) |*c| {
            c.off = off;
            off.add(c);
        }
        inline for (table_names) |f| {
            try @field(p.ast, f).ensureTotalCapacity(p.gpa, @field(off, f));
            @field(p.ast, f).items.len = @field(off, f);
        }
        try p.sc_binds.ensureTotalCapacity(p.gpa, off.sc_binds);
        p.sc_binds.items.len = off.sc_binds;
        try p.ind_strs.ensureTotalCapacity(p.gpa, off.ind_strs);
        p.ind_strs.items.len = off.ind_strs;
        try p.lx.allows.ensureTotalCapacity(p.gpa, off.allows);
        p.lx.allows.items.len = off.allows;
        job.phase = .move;
        p.interner = par.run(par.ctx, @intCast(n), &job, ChunkJob.run);

        const last = &chunks[n - 1];
        p.tok = null;
        p.next = null;
        p.lx.pos = last.end;
        p.lx.noted_to = @max(p.lx.noted_to, last.end);
        p.last_end = last.last_end;
    }

    fn staticInheritName(p: *Parser, elem: AttrElem, t: Token) error{SyntaxError}!Sym {
        return switch (elem) {
            .static => |s| s,
            .dynamic => p.fail(t.start, "dynamic attributes not allowed in inherit", .{}),
        };
    }

    fn checkDupAttrs(p: *Parser, range: Range) callconv(ast_mod.inline_release) Error!void {
        return p.across(checkDupAttrsBody, .{range});
    }

    fn checkDupAttrsBody(p: *Parser, range: Range) Error!void {
        const binds = p.ast.bindsOf(range);
        const needs_check = switch (binds.len) {
            0 => false,
            1 => binds[0].kind == .inherit and binds[0].kind.inherit.names.len > 1,
            else => true,
        };
        if (!needs_check or flatNamesDistinct(&p.ast, binds)) return;
        defer p.dup_arena.reset();
        var cx: DupCx = .{ .p = p, .arena = p.dup_arena.allocator() };
        var map: SymMap = .{};
        try cx.addBinds(&map, binds);
    }
};

/// What `Parser.parallelBinds` runs jobs on: `run` calls `job(job_ctx, i,
/// interner)` for every `i < n`, on any threads, each with an interner
/// handle that thread may use, and returns when all are done.
pub const Parallel = struct {
    ctx: *anyopaque,
    workers: u32,
    /// Returns the interner the caller uses from then on: its thread may
    /// have changed while it waited.
    run: *const fn (ctx: *anyopaque, n: u32, job_ctx: *anyopaque, job: *const fn (job_ctx: *anyopaque, i: u32, interner: *Interner) void) *Interner,
};

/// Source left in a set before its bindings are parsed in chunks.
const chunked_min = 512 << 10;
const max_chunks = 64;
/// The last chunk's end stays this far from the end of the file, where the
/// set may close.
const chunk_tail = 32 << 10;

const table_names = .{ "tags", "data", "spans", "ids", "elems", "parts", "bytes", "binds", "names", "patterns", "formals", "notes" };

/// Where a chunk's entries go in each table.
const Offsets = struct {
    tags: usize = 0,
    data: usize = 0,
    spans: usize = 0,
    ids: usize = 0,
    elems: usize = 0,
    parts: usize = 0,
    bytes: usize = 0,
    binds: usize = 0,
    names: usize = 0,
    patterns: usize = 0,
    formals: usize = 0,
    notes: usize = 0,
    sc_binds: usize = 0,
    ind_strs: usize = 0,
    allows: usize = 0,

    fn of(p: *const Parser) Offsets {
        var o: Offsets = .{ .sc_binds = p.sc_binds.items.len, .ind_strs = p.ind_strs.items.len, .allows = p.lx.allows.items.len };
        inline for (table_names) |f| @field(o, f) = @field(p.ast, f).items.len;
        return o;
    }

    fn add(o: *Offsets, c: *const Chunk) void {
        inline for (table_names) |f| @field(o, f) += @field(c.ast, f).items.len;
        o.sc_binds += c.binds.items.len;
        o.ind_strs += c.ind_strs.items.len;
        o.allows += c.allows.items.len;
    }
};

const Chunk = struct {
    start: u32,
    end: u32,
    ok: bool = false,
    last_end: u32 = 0,
    ast: Ast = .{},
    /// The bindings, in the chunk's tables.
    binds: std.ArrayList(Bind) = .empty,
    ind_strs: std.ArrayList(Parser.IndStr) = .empty,
    allows: std.ArrayList([2]u32) = .empty,
    off: Offsets = .{},

    fn deinit(c: *Chunk, gpa: Allocator) void {
        c.ast.deinit(gpa);
        c.binds.deinit(gpa);
        c.ind_strs.deinit(gpa);
        c.allows.deinit(gpa);
    }
};

const ChunkJob = struct {
    p: *Parser,
    chunks: []Chunk,
    phase: enum { parse, move },

    fn run(ctx: *anyopaque, i: u32, interner: *Interner) void {
        const j: *ChunkJob = @ptrCast(@alignCast(ctx));
        const c = &j.chunks[i];
        switch (j.phase) {
            .parse => parseChunk(j.p, c, interner),
            .move => moveChunk(j.p, c),
        }
    }
};

/// The chunk's bindings, as a parser of its own reads them; `ok` when
/// they run to the chunk's end exactly.
fn parseChunk(main: *const Parser, c: *Chunk, interner: *Interner) void {
    var d: Diag = .init(main.gpa);
    defer d.deinit();
    var p = Parser.initSized(main.gpa, main.src[0..c.end], interner, .{}, &d, c.end - c.start) catch return;
    defer p.deinit();
    p.lx.pos = c.start;
    p.lx.noted_to = c.start;
    p.depth = main.depth;
    // Never chunked again inside a chunk.
    p.par_tried = true;
    p.parseBindsUntil(.eof) catch return;
    c.ok = true;
    c.last_end = p.last_end;
    c.ast = p.ast;
    p.ast = .{};
    c.binds = p.sc_binds;
    p.sc_binds = .empty;
    c.ind_strs = p.ind_strs;
    p.ind_strs = .empty;
    c.allows = p.lx.allows;
    p.lx.allows = .empty;
}

/// Copy the chunk's entries into the main tables at its offsets, every
/// node and range shifted by them.
fn moveChunk(p: *Parser, c: *Chunk) void {
    const o = c.off;
    const node: u32 = @intCast(o.tags);
    const a = &p.ast;
    const src = &c.ast;
    const R = struct {
        inline fn id(e: ExprId, k: u32) ExprId {
            return if (e == .none) .none else @fromBackingInt(e.index() + k);
        }
        inline fn range(r: Range, k: usize) Range {
            return .{ .start = r.start + @as(u32, @intCast(k)), .len = r.len };
        }
    };
    @memcpy(a.tags.items[o.tags..][0..src.tags.items.len], src.tags.items);
    @memcpy(a.spans.items[o.spans..][0..src.spans.items.len], src.spans.items);
    @memcpy(a.bytes.items[o.bytes..][0..src.bytes.items.len], src.bytes.items);
    @memcpy(a.names.items[o.names..][0..src.names.items.len], src.names.items);
    for (src.tags.items, src.data.items, a.data.items[o.data..][0..src.data.items.len]) |t, d, *out| {
        const e: Expr = switch (Expr.join(t, d)) {
            .int, .float, .@"var" => Expr.join(t, d),
            .str => |r| .{ .str = R.range(r, o.parts) },
            .path => |x| .{ .path = .{ .kind = x.kind, .parts = R.range(x.parts, o.parts) } },
            .select => |x| .{ .select = .{ .subject = R.id(x.subject, node), .path = R.range(x.path, o.elems), .default = R.id(x.default, node) } },
            .has_attr => |x| .{ .has_attr = .{ .subject = R.id(x.subject, node), .path = R.range(x.path, o.elems) } },
            .attrs => |x| .{ .attrs = .{ .rec = x.rec, .binds = R.range(x.binds, o.binds) } },
            .list => |r| .{ .list = R.range(r, o.ids) },
            .lambda => |x| .{ .lambda = .{ .arg = x.arg, .body = R.id(x.body, node) } },
            .lambda_pattern => |x| .{ .lambda_pattern = .{ .pattern = x.pattern + @as(u32, @intCast(o.patterns)), .body = R.id(x.body, node) } },
            .apply => |x| .{ .apply = .{ .func = R.id(x.func, node), .args = R.range(x.args, o.ids) } },
            .let => |x| .{ .let = .{ .binds = R.range(x.binds, o.binds), .body = R.id(x.body, node) } },
            .with => |x| .{ .with = .{ .scope = R.id(x.scope, node), .body = R.id(x.body, node) } },
            .@"if" => |x| .{ .@"if" = .{ .cond = R.id(x.cond, node), .then = R.id(x.then, node), .@"else" = R.id(x.@"else", node) } },
            .assert => |x| .{ .assert = .{ .cond = R.id(x.cond, node), .body = R.id(x.body, node) } },
            .unary => |x| .{ .unary = .{ .op = x.op, .expr = R.id(x.expr, node) } },
            .binary => |x| .{ .binary = .{ .op = x.op, .lhs = R.id(x.lhs, node), .rhs = R.id(x.rhs, node) } },
        };
        out.* = e.split()[1];
    }
    for (src.ids.items, a.ids.items[o.ids..][0..src.ids.items.len]) |x, *out| out.* = R.id(x, node);
    for (src.elems.items, a.elems.items[o.elems..][0..src.elems.items.len]) |x, *out| out.* = switch (x) {
        .static => x,
        .dynamic => |e| .{ .dynamic = R.id(e, node) },
    };
    for (src.parts.items, a.parts.items[o.parts..][0..src.parts.items.len]) |x, *out| out.* = switch (x) {
        .lit => |r| .{ .lit = R.range(r, o.bytes) },
        .interp => |e| .{ .interp = R.id(e, node) },
    };
    const B = struct {
        inline fn bind(b: Bind, k: u32, of: Offsets) Bind {
            return .{ .span = b.span, .kind = switch (b.kind) {
                .value => |v| .{ .value = .{ .path = R.range(v.path, of.elems), .value = R.id(v.value, k) } },
                .inherit => |h| .{ .inherit = .{ .from = R.id(h.from, k), .names = R.range(h.names, of.names) } },
            } };
        }
    };
    for (src.binds.items, a.binds.items[o.binds..][0..src.binds.items.len]) |x, *out| out.* = B.bind(x, node, o);
    for (c.binds.items, p.sc_binds.items[o.sc_binds..][0..c.binds.items.len]) |x, *out| out.* = B.bind(x, node, o);
    for (src.patterns.items, a.patterns.items[o.patterns..][0..src.patterns.items.len]) |x, *out|
        out.* = .{ .bind = x.bind, .formals = R.range(x.formals, o.formals), .ellipsis = x.ellipsis };
    for (src.formals.items, a.formals.items[o.formals..][0..src.formals.items.len]) |x, *out|
        out.* = .{ .name = x.name, .default = R.id(x.default, node), .span = x.span };
    for (src.notes.items, a.notes.items[o.notes..][0..src.notes.items.len]) |x, *out| out.* = switch (x) {
        .url => |e| .{ .url = R.id(e, node) },
    };
    for (c.ind_strs.items, p.ind_strs.items[o.ind_strs..][0..c.ind_strs.items.len]) |x, *out|
        out.* = .{ .id = R.id(x.id, node), .concat = x.concat };
    @memcpy(p.lx.allows.items[o.allows..][0..c.allows.items.len], c.allows.items);
}

/// Chunk boundaries for the bindings from `start` on, about evenly
/// spaced, in `out[0..n + 1]`; null when the source offers too few.
fn chunkBounds(src: []const u8, start: u32, want: usize, out: []u32) ?usize {
    // The first binding's indentation; it must stand on a line of its own.
    var ls: usize = start;
    while (ls > 0 and src[ls - 1] == ' ') ls -= 1;
    if (ls > 0 and src[ls - 1] != '\n') return null;
    const indent = start - ls;
    if (src.len < chunk_tail + start) return null;
    const end = src.len - chunk_tail;
    const step = (end - start) / want;
    if (step < 64 << 10) return null;
    out[0] = start;
    var n: usize = 0;
    var target: usize = start + step;
    while (n + 1 < want and target < end) {
        const b = nextBoundary(src, target, end, indent) orelse break;
        n += 1;
        out[n] = @intCast(b);
        target = b + step;
    }
    if (n < 2) return null;
    return n;
}

/// The first line start at or after `from` and before `end` indented by
/// exactly `indent` spaces and then a name, after a line ending in `;`
/// (blank lines between).
fn nextBoundary(src: []const u8, from: usize, end: usize, indent: usize) ?usize {
    var i = from;
    while (std.mem.findScalarPos(u8, src[0..end], i, '\n')) |nl| {
        i = nl + 1;
        const b = nl + 1;
        if (b + indent >= end) return null;
        const line = src[b..];
        if (!std.mem.allEqual(u8, line[0..indent], ' ')) continue;
        const c = line[indent];
        if (!(std.ascii.isAlphabetic(c) or c == '_' or c == '"')) continue;
        var k = nl;
        while (k > 0 and (src[k - 1] == ' ' or src[k - 1] == '\t' or src[k - 1] == '\r' or src[k - 1] == '\n')) k -= 1;
        if (k > 0 and src[k - 1] == ';') return b;
    }
    return null;
}

fn parseInt(txt: []const u8) ?i64 {
    var v: u64 = 0;
    for (txt) |b| {
        v = std.math.mul(u64, v, 10) catch return null;
        v = std.math.add(u64, v, b - '0') catch return null;
    }
    return std.math.cast(i64, v);
}

/// Port of `ParserState::stripIndentation` from Nix. Token boundaries
/// matter: only the last token loses a trailing whitespace-only line.
/// Output text goes to `bytes`, the parts to `out`. Returns how many
/// pieces Nix keeps: the tokens whose text is not empty, and the
/// interpolations.
fn stripIndentation(
    gpa: Allocator,
    src: []const u8,
    parts: []const IndPart,
    interps: []const ExprId,
    bytes: *std.ArrayList(u8),
    out: *std.ArrayList(StrPart),
) !usize {
    const out_mark = out.items.len;
    if (parts.len == 0) {
        try out.append(gpa, .{ .lit = .{ .start = @intCast(bytes.items.len), .len = 0 } });
        return 0;
    }
    var at_start = true;
    var min_indent: usize = std.math.maxInt(usize);
    var cur_indent: usize = 0;
    for (parts) |part| switch (part) {
        .src => |s| {
            const seg = src[s.start..s.end];
            var k: usize = 0;
            while (k < seg.len) {
                const b = seg[k];
                k += 1;
                if (at_start) {
                    if (b == ' ') {
                        cur_indent += 1;
                    } else if (b == '\n') {
                        cur_indent = 0;
                    } else {
                        at_start = false;
                        min_indent = @min(min_indent, cur_indent);
                    }
                } else {
                    if (b != '\n') {
                        const j = std.mem.findScalarPos(u8, seg, k, '\n') orelse break;
                        k = j + 1;
                    }
                    at_start = true;
                    cur_indent = 0;
                }
            }
        },
        .lit, .interp => if (at_start) {
            at_start = false;
            min_indent = @min(min_indent, cur_indent);
        },
    };

    // the literal run being built is bytes[pending_start..]
    var pending_start = bytes.items.len;
    var interp_i: usize = 0;
    var pieces: usize = 0;
    at_start = true;
    var cur_dropped: usize = 0;
    for (parts, 0..) |part, idx| {
        const last = idx + 1 == parts.len;
        const txt: []const u8 = switch (part) {
            .interp => {
                at_start = false;
                cur_dropped = 0;
                if (bytes.items.len > pending_start) {
                    try out.append(gpa, .{ .lit = .{ .start = @intCast(pending_start), .len = @intCast(bytes.items.len - pending_start) } });
                    pending_start = bytes.items.len;
                }
                try out.append(gpa, .{ .interp = interps[interp_i] });
                interp_i += 1;
                pieces += 1;
                continue;
            },
            .src => |s| src[s.start..s.end],
            .lit => |*l| l.bytes[0..l.len],
        };
        const before = bytes.items.len;
        try trimInto(gpa, bytes, txt, min_indent, &at_start, &cur_dropped);
        if (last) dropTrailingBlankLine(bytes, before);
        if (bytes.items.len > before) pieces += 1;
    }
    if (bytes.items.len > pending_start)
        try out.append(gpa, .{ .lit = .{ .start = @intCast(pending_start), .len = @intCast(bytes.items.len - pending_start) } });
    if (out.items.len == out_mark)
        try out.append(gpa, .{ .lit = .{ .start = @intCast(bytes.items.len), .len = 0 } });
    return pieces;
}

fn trimInto(gpa: Allocator, out: *std.ArrayList(u8), bytes: []const u8, min_indent: usize, at_start: *bool, cur_dropped: *usize) !void {
    var k: usize = 0;
    while (k < bytes.len) {
        if (at_start.*) {
            const b = bytes[k];
            k += 1;
            if (b == ' ') {
                if (cur_dropped.* >= min_indent) try out.append(gpa, b);
                cur_dropped.* += 1;
            } else if (b == '\n') {
                cur_dropped.* = 0;
                try out.append(gpa, b);
            } else {
                at_start.* = false;
                cur_dropped.* = 0;
                try out.append(gpa, b);
            }
        } else {
            const end = if (std.mem.findScalarPos(u8, bytes, k, '\n')) |j| j + 1 else bytes.len;
            try out.appendSlice(gpa, bytes[k..end]);
            at_start.* = bytes[end - 1] == '\n';
            k = end;
        }
    }
}

/// If the text produced by the last token ends in a line of only spaces,
/// remove that line (keep the newline before it).
fn dropTrailingBlankLine(pending: *std.ArrayList(u8), token_start: usize) void {
    const tail = pending.items[token_start..];
    const nl = std.mem.findScalarLast(u8, tail, '\n') orelse return;
    if (std.mem.findNone(u8, tail[nl + 1 ..], " ") == null)
        pending.shrinkRetainingCapacity(token_start + nl + 1);
}

// duplicate attribute detection, mirrors ParserState::addAttr

const Node = struct {
    sym: Sym,
    pos: u32,
    kind: union(enum) {
        leaf,
        /// A literal attrset value not yet expanded into a map.
        lazy: ExprId,
        map: SymMap,
    },
};

const index_threshold = 16;

const SymMap = struct {
    nodes: std.ArrayList(Node) = .empty,
    index: std.AutoHashMapUnmanaged(Sym, u32) = .empty,

    fn find(m: *const SymMap, s: Sym) ?usize {
        if (m.nodes.items.len > index_threshold) return if (m.index.get(s)) |i| i else null;
        for (m.nodes.items, 0..) |n, i| if (n.sym == s) return i;
        return null;
    }

    fn insert(m: *SymMap, arena: Allocator, node: Node) !usize {
        const i = m.nodes.items.len;
        if (i == index_threshold) {
            for (m.nodes.items, 0..) |n, j| try m.index.put(arena, n.sym, @intCast(j));
        }
        if (i >= index_threshold) try m.index.put(arena, node.sym, @intCast(i));
        try m.nodes.append(arena, node);
        return i;
    }
};

const DupCx = struct {
    p: *Parser,
    arena: Allocator,
    prefix: std.ArrayList(Sym) = .empty,

    fn bindsOf(cx: *DupCx, e: ExprId) []const Bind {
        return switch (cx.p.ast.expr(e)) {
            .attrs => |a| cx.p.ast.bindsOf(a.binds),
            else => unreachable,
        };
    }

    fn dup(cx: *DupCx, pos: u32, prev: u32) Error {
        var w: std.Io.Writer.Allocating = .init(cx.arena);
        for (cx.prefix.items, 0..) |s, i| {
            if (i > 0) w.writer.writeByte('.') catch return error.OutOfMemory;
            w.writer.writeAll(cx.p.interner.nameStr(s)) catch return error.OutOfMemory;
        }
        const l, const c = text.lineCol(cx.p.src, prev);
        return cx.p.fail(pos, "attribute '{s}' already defined at {d}:{d}", .{ w.written(), l, c });
    }

    fn expand(cx: *DupCx, node: *Node) Error!void {
        switch (node.kind) {
            .lazy => |e| {
                var m: SymMap = .{};
                try cx.addBinds(&m, cx.bindsOf(e));
                node.kind = .{ .map = m };
            },
            else => {},
        }
    }

    fn addBinds(cx: *DupCx, map: *SymMap, binds: []const Bind) Error!void {
        const depth = cx.prefix.items.len;
        for (binds) |b| {
            switch (b.kind) {
                .value => |v| try cx.addPath(map, cx.p.ast.elemsOf(v.path), v.value, b.span.start),
                .inherit => |inh| for (cx.p.ast.namesOf(inh.names)) |n| {
                    try cx.addLeaf(map, n.sym, .none, n.span.start);
                    cx.prefix.shrinkRetainingCapacity(depth);
                },
            }
            cx.prefix.shrinkRetainingCapacity(depth);
        }
    }

    fn addPath(cx: *DupCx, map0: *SymMap, path: []const AttrElem, value: ExprId, pos: u32) Error!void {
        var map = map0;
        for (path[0 .. path.len - 1]) |elem| {
            const s = switch (elem) {
                .static => |s| s,
                .dynamic => return,
            };
            try cx.prefix.append(cx.arena, s);
            const idx = map.find(s) orelse
                try map.insert(cx.arena, .{ .sym = s, .pos = pos, .kind = .{ .map = .{} } });
            const node = &map.nodes.items[idx];
            switch (node.kind) {
                .leaf => return cx.dup(pos, node.pos),
                .lazy => try cx.expand(node),
                .map => {},
            }
            map = &map.nodes.items[idx].kind.map;
        }
        switch (path[path.len - 1]) {
            .static => |s| try cx.addLeaf(map, s, value, pos),
            .dynamic => {},
        }
    }

    fn addLeaf(cx: *DupCx, map: *SymMap, s: Sym, value: ExprId, pos: u32) Error!void {
        try cx.prefix.append(cx.arena, s);
        const attrs_val: ExprId = if (value != .none and cx.p.ast.tag(value) == .attrs) value else .none;
        const i = map.find(s) orelse {
            _ = try map.insert(cx.arena, .{
                .sym = s,
                .pos = pos,
                .kind = if (attrs_val != .none) .{ .lazy = attrs_val } else .leaf,
            });
            return;
        };
        const node = &map.nodes.items[i];
        if (attrs_val == .none or node.kind == .leaf) return cx.dup(pos, node.pos);
        try cx.expand(node);
        try cx.addBinds(&node.kind.map, cx.bindsOf(attrs_val));
    }
};

/// Most sets bind only plain names. With no name twice there is nothing to
/// report, and the full check, which merges nested sets, is skipped.
fn flatNamesDistinct(a: *const Ast, binds: []const Bind) bool {
    var syms: [32]u32 = undefined;
    var n: usize = 0;
    for (binds) |b| switch (b.kind) {
        .value => |v| {
            const path = a.elemsOf(v.path);
            if (path.len != 1 or path[0] != .static or n == syms.len) return false;
            syms[n] = path[0].static.index();
            n += 1;
        },
        .inherit => |inh| for (a.namesOf(inh.names)) |name| {
            if (n == syms.len) return false;
            syms[n] = name.sym.index();
            n += 1;
        },
    };
    return distinct(syms[0..n]);
}

/// No two of the names are equal: pairwise for the usual few, where a sort
/// costs more than it saves. Only `true` is a fast path; a clash is found
/// again by the caller's slow check, which picks the one Nix reports.
fn distinct(syms: []u32) bool {
    if (syms.len > 16) {
        std.mem.sortUnstable(u32, syms, {}, std.sort.asc(u32));
        for (syms[0 .. syms.len - 1], syms[1..]) |x, y| if (x == y) return false;
        return true;
    }
    for (syms, 0..) |x, i| for (syms[0..i]) |y| if (x == y) return false;
    return true;
}

fn formalsDistinct(formals: []const Formal) bool {
    var syms: [16]u32 = undefined;
    if (formals.len > syms.len) return false;
    for (formals, syms[0..formals.len]) |f, *x| x.* = f.name.index();
    return distinct(syms[0..formals.len]);
}
