//! Lint configurations, scope and `# iets: allow`, evaluated in this
//! process. The fixtures and the command-line cases run against the Rust
//! oracle in
//! `scripts/lint-parity.sh`.

const std = @import("std");
const testing = std.testing;
const lint = @import("../lint.zig");
const Evaluator = @import("../eval/Evaluator.zig");
const Files = @import("../eval/Files.zig");
const Interner = @import("../syntax/symbol.zig").Interner;
const builtins = @import("../builtins.zig");
const import_ = @import("../eval/import.zig");
const value = @import("../runtime/value.zig");
const ir_cache = @import("../ir_cache.zig");

const Run = struct {
    interner: Interner,
    files: Files,
    shared: Evaluator.Shared = .{},
    local: Evaluator.Local,
    ev: Evaluator,
    cfg: lint.Config,
    arena: std.heap.ArenaAllocator,

    /// An evaluator under `pairs` (`NAME=LEVEL`, as `--lint` takes them).
    fn init(r: *Run, pairs: []const []const u8) !void {
        const gpa = testing.allocator;
        const io = testing.io;
        r.arena = .init(gpa);
        r.cfg = .{};
        var dg: @import("../diag.zig").Diag = .init(r.arena.allocator());
        for (pairs) |p| try r.cfg.setPair(p, &dg);
        r.interner = try .init(gpa);
        r.files = .init(gpa, io);
        r.shared = .{};
        r.local = .init(gpa);
        value.flat_arena = &r.local.arena;
        r.ev = try .init(gpa, io, &r.local, &r.interner, &r.files, &r.shared, .{ .lints = &r.cfg });
        try builtins.install(&r.ev);
    }

    fn deinit(r: *Run) void {
        r.ev.deinit();
        value.flat_arena = null;
        r.local.deinit();
        r.shared.deinit(testing.allocator);
        r.files.deinit();
        r.interner.deinit();
        r.arena.deinit();
    }

    /// `src` as the entry expression (a lint root), forced deeply.
    fn eval(r: *Run, src: []const u8) !void {
        _ = try r.ev.forceDeep(try import_.evalString(&r.ev, src));
    }

    /// `src` as the file `path`, forced deeply.
    fn evalAt(r: *Run, path: []const u8, src: []const u8) !void {
        const code = try import_.compileSource(&r.ev, path, src, "/", null);
        _ = try r.ev.forceDeep(try r.ev.eval(r.ev.root_env, code));
    }

    fn records(r: *Run) []const []u8 {
        return lint.report.records(&r.ev);
    }
};

test "one warning per site" {
    var r: Run = undefined;
    try r.init(&.{"eq-type-mismatch=warn"});
    defer r.deinit();
    try r.eval("let f = x: x == \"a\"; in [ (f 1) (f 2) (f 3) ]");
    try testing.expectEqual(1, r.records().len);
    try testing.expect(std.mem.startsWith(u8, r.records()[0], "warning: [eq-type-mismatch] `==` compares an integer with a string"));
    try testing.expect(std.mem.endsWith(u8, r.records()[0], "\n  at «string»:1:12"));
}

test "tryEval does not catch a lint error" {
    var r: Run = undefined;
    try r.init(&.{"eq-type-mismatch=error"});
    defer r.deinit();
    try testing.expectError(error.EvalFailed, r.eval("(builtins.tryEval (1 == \"a\")).success"));
    try testing.expectEqual(Evaluator.ErrorKind.lint, r.ev.failureKind().?);
    try testing.expect(std.mem.startsWith(u8, r.ev.failure.?.msg, "[eq-type-mismatch] "));
}

test "an allow comment silences its line, at any level" {
    var r: Run = undefined;
    try r.init(&.{ "eq-type-mismatch=error", "url-literal=error" });
    defer r.deinit();
    try r.eval("# iets: allow eq-type-mismatch, family:legacy\n[ (1 == \"a\") http://x.y ]");
    try r.eval("[ (1 == \"b\") ] # iets: allow all");
    try testing.expectEqual(0, r.records().len);
    // a blank line between still covers the next line of code; another lint's name does not
    try r.eval("# iets: allow eq-type-mismatch\n\n[ (1 == \"c\") ]\n");
    try testing.expectError(error.EvalFailed, r.eval("[\n(1 == \"d\") # iets: allow url-literal\n]"));
}

test "an unknown allow name is a warning of its own" {
    var r: Run = undefined;
    try r.init(&.{});
    defer r.deinit();
    try r.eval("# iets: allow nope\n1");
    try testing.expectEqual(1, r.records().len);
    try testing.expectEqualStrings("warning: [unknown-allow] unknown lint 'nope' in `# iets: allow`\n  at «string»:1:15", r.records()[0]);
}

test "the scope keeps a site outside the roots silent until it is opened" {
    var r: Run = undefined;
    try r.init(&.{"or-non-attrs=warn"});
    defer r.deinit();
    try r.evalAt("/elsewhere/a.nix", "(1).a or 2");
    try testing.expectEqual(0, r.records().len);
    try r.cfg.addRoot(r.arena.allocator(), "/elsewhere");
    try r.evalAt("/elsewhere/b.nix", "(1).a or 2");
    try testing.expectEqual(1, r.records().len);
    r.cfg.roots = .empty;
    r.cfg.scope = .all;
    try r.evalAt("/other/c.nix", "(1).a or 2");
    try testing.expectEqual(2, r.records().len);
}

test "the defaults report a checkout path in a derivation of the entry" {
    var r: Run = undefined;
    try r.init(&.{});
    defer r.deinit();
    try testing.expectError(error.EvalFailed, r.eval("(derivation { name = \"x\"; system = \"s\"; builder = \"b\"; src = toString /etc/iets-lint-x; }).drvPath"));
    try testing.expectEqual(Evaluator.ErrorKind.lint, r.ev.failureKind().?);
    try testing.expect(std.mem.startsWith(u8, r.ev.failure.?.msg, "[impure-path-in-drv] derivation 'x': attribute 'src'"));
}

test "an IR cache entry carries the warnings and the allow table" {
    var r: Run = undefined;
    try r.init(&.{"url-literal=warn"});
    defer r.deinit();
    const src = "# iets: allow eq-type-mismatch\n[ http://a.b (1 == \"x\") ]";
    const file = try r.files.add("/t.nix", src);
    var diags: std.ArrayList(lint.Diag) = .empty;
    defer {
        for (diags.items) |dg| testing.allocator.free(dg.msg);
        diags.deinit(testing.allocator);
    }
    const code = try import_.compileSource(&r.ev, "/t.nix", src, "/", null);
    const compiled = r.files.files.items[r.files.files.items.len - 1];
    try diags.append(testing.allocator, .{ .id = .url_literal, .pos = .at(compiled.base + 33), .msg = try testing.allocator.dupe(u8, "m") });
    const entry = (try ir_cache.serialize(&r.ev, code, compiled.base, diags.items, &compiled.allows)).?;
    defer testing.allocator.free(entry);
    var loaded = (try ir_cache.deserialize(&r.ev, entry, file.base, src.len)).?;
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(1, loaded.diags.items.len);
    try testing.expectEqual(lint.LintId.url_literal, loaded.diags.items[0].id);
    try testing.expectEqual(file.base + 33, @backingInt(loaded.diags.items[0].pos));
    try testing.expectEqual(1, loaded.allows.lines.items.len);
    try testing.expect(loaded.allows.covers(33, .eq_type_mismatch));
}

test "the site of a finding is its node's span, with Nix's edit" {
    var r: Run = undefined;
    try r.init(&.{"url-literal=warn"});
    defer r.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "u.nix", .data = "[ 1 http://example.com ]" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", r.arena.allocator());
    const path = try std.fs.path.join(r.arena.allocator(), &.{ dir, "u.nix" });
    const file = try r.files.add(path, "[ 1 http://example.com ]");
    const s = (try lint.report.siteOf(&r.ev, r.arena.allocator(), .url_literal, .at(file.base + 4))).?;
    try testing.expectEqual(4, s.start);
    try testing.expectEqual(22, s.end);
    try testing.expectEqualStrings("\"http://example.com\"", s.replacement.?);
}
