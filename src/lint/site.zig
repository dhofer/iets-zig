//! The byte span of a finding, and the edit when the lint has one
//! (docs/reference/errors.md). A site is the offset where a node starts,
//! and the IR keeps nothing more. Nodes share a start when one is the first
//! operand of the next (`a`, `a.b`, `a.b c`, `a.b c == d`), so the span is
//! that of the innermost node there of a kind the lint reports at.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast_mod = @import("../syntax/ast.zig");
const Ast = ast_mod.Ast;
const Span = ast_mod.Span;
const ExprId = ast_mod.ExprId;
const LintId = @import("../lint.zig").LintId;

/// A place in a file as byte offsets, and the text to put there.
pub const Site = struct {
    start: u32,
    end: u32,
    /// Owned by the allocator `finding` was given; null without an edit.
    replacement: ?[]const u8 = null,
};

const Kind = enum { interp, add, apply, coercion, path, string, eq, @"or", select, @"var" };

fn is(a: *const Ast, id: ExprId, k: Kind) bool {
    const e = a.expr(id);
    return switch (k) {
        .interp => e == .str and for (a.partsOf(e.str)) |p| {
            if (p == .interp) break true;
        } else false,
        .add => e == .binary and e.binary.op == .add,
        .apply => e == .apply,
        .coercion => is(a, id, .interp) or is(a, id, .add) or is(a, id, .apply),
        .path => e == .path,
        .string => e == .str,
        .eq => e == .binary and (e.binary.op == .eq or e.binary.op == .ne),
        .@"or" => e == .select and e.select.default != .none,
        .select => e == .select,
        .@"var" => e == .@"var",
    };
}

/// The span of the site of `id` at offset `off` of `src`, which parsed
/// into `tree`, and the text that replaces it.
pub fn finding(a: Allocator, src: []const u8, tree: *const Ast, id: LintId, off: u32) Allocator.Error!?Site {
    // first choice first; `true` when a binding at the site goes before them
    const binds: bool, const kinds: []const Kind = switch (id) {
        .absolute_path_literal, .short_path_literal => .{ false, &.{.path} },
        .url_literal => .{ false, &.{.string} },
        .eq_type_mismatch, .eq_function => .{ false, &.{.eq} },
        .or_non_attrs => .{ false, &.{.@"or"} },
        .impure_builtin => .{ false, &.{ .apply, .select, .@"var" } },
        .unhashed_fetch, .ifd, .ifd_local_output, .read_through_copy => .{ false, &.{.apply} },
        // `inherit (self) revCount`, then `getAttr "revCount" self`: the
        // call starts where its `builtins.getAttr` starts
        .rev_count => .{ true, &.{ .apply, .select } },
        .unknown_allow => {
            if (off > src.len) return null;
            var len: u32 = 0;
            while (off + len < src.len and std.mem.indexOfScalar(u8, " \t,\r\n", src[off + len]) == null) len += 1;
            return if (len > 0) .{ .start = off, .end = off + len } else null;
        },
        else => .{ true, &.{.coercion} },
    };
    var span: ?Span = null;
    if (binds) {
        for (tree.names.items) |n| if (n.span.start == off) {
            span = n.span;
            break;
        };
        if (span == null) for (tree.binds.items) |b| if (b.span.start == off) {
            span = b.span;
            break;
        };
    }
    if (span == null) for (kinds) |k| {
        var best: ?Span = null;
        for (tree.spans.items, 0..) |s, i| {
            if (s.start != off) continue;
            if (!is(tree, @fromBackingInt(@intCast(i)), k)) continue;
            if (best == null or s.end < best.?.end) best = s;
        }
        if (best) |b| {
            span = b;
            break;
        }
    };
    const sp = span orelse return null;
    if (sp.end > src.len or sp.start > sp.end) return null;
    const text = src[sp.start..sp.end];
    const edit: ?[]const u8 = switch (id) {
        .url_literal => if (text.len > 0 and (text[0] == '"' or text[0] == '\'')) null else try std.fmt.allocPrint(a, "\"{s}\"", .{text}),
        .short_path_literal => try std.fmt.allocPrint(a, "./{s}", .{text}),
        else => null,
    };
    return .{ .start = sp.start, .end = sp.end, .replacement = edit };
}

const testing = std.testing;

fn at(src: []const u8, id: LintId, s: []const u8) !?struct { []const u8, ?[]const u8 } {
    const syntax = @import("../syntax.zig");
    var interner: syntax.Interner = try .init(testing.allocator);
    defer interner.deinit();
    var dg: syntax.Diag = .init(testing.allocator);
    defer dg.deinit();
    var off: u32 = 0;
    var tree = try syntax.parseParallel(testing.allocator, .{}, src, @fromBackingInt(0), &interner, &dg, &off, null);
    defer tree.deinit(testing.allocator);
    const o: u32 = @intCast(std.mem.indexOf(u8, src, s).?);
    const f = (try finding(testing.allocator, src, &tree, id, o)) orelse return null;
    return .{ src[f.start..f.end], f.replacement };
}

fn expectSpan(src: []const u8, id: LintId, s: []const u8, want: ?[]const u8) !void {
    const got = try at(src, id, s);
    defer if (got) |g| if (g[1]) |r| testing.allocator.free(r);
    if (want) |w| {
        try testing.expectEqualStrings(w, got.?[0]);
    } else try testing.expect(got == null);
}

test "the span is the innermost node of the kind of the lint" {
    try expectSpan("a.b == 1 && c", .eq_type_mismatch, "a", "a.b == 1");
    try expectSpan("x: x.a or 1 + 2", .or_non_attrs, "x.a", "x.a or 1");
    const src = "builtins.getEnv \"A\" == builtins.currentTime";
    try expectSpan(src, .impure_builtin, "builtins", "builtins.getEnv \"A\"");
    try expectSpan(src, .impure_builtin, "builtins.c", "builtins.currentTime");
    const s2 = "{ src = \"a\" + ./b + \"c\"; inherit d; e = \"${./f}\" + \"g\"; }";
    try expectSpan(s2, .path_copy, "\"a\"", "\"a\" + ./b");
    try expectSpan(s2, .path_copy, "\"${", "\"${./f}\"");
    try expectSpan(s2, .path_copy, "src", "src = \"a\" + ./b + \"c\";");
    try expectSpan(s2, .drv_list, "d;", "d");
    try expectSpan(s2, .path_copy, "= \"a\"", null);
    try expectSpan("# iets: allow nope, fod\n1", .unknown_allow, "nope", "nope");
}

test "a literal lint of nix has an edit" {
    const url = "[ http://a.b/c?d=1 \"http://e.f\" ]";
    var got = (try at(url, .url_literal, "http")).?;
    try testing.expectEqualStrings("http://a.b/c?d=1", got[0]);
    try testing.expectEqualStrings("\"http://a.b/c?d=1\"", got[1].?);
    testing.allocator.free(got[1].?);
    got = (try at(url, .url_literal, "\"http")).?;
    try testing.expectEqualStrings("\"http://e.f\"", got[0]);
    try testing.expect(got[1] == null);
    const p = "a/b + c/${d}";
    got = (try at(p, .short_path_literal, "a/b")).?;
    try testing.expectEqualStrings("a/b", got[0]);
    try testing.expectEqualStrings("./a/b", got[1].?);
    testing.allocator.free(got[1].?);
    got = (try at(p, .short_path_literal, "c/")).?;
    try testing.expectEqualStrings("c/${d}", got[0]);
    try testing.expectEqualStrings("./c/${d}", got[1].?);
    testing.allocator.free(got[1].?);
    got = (try at("/a", .absolute_path_literal, "/a")).?;
    try testing.expectEqualStrings("/a", got[0]);
}
