//! The path-literal lints Nix has (`lint-absolute-path-literals`,
//! `lint-short-path-literals`), with Nix's messages. Hook: the compiler, at
//! every path literal.

const std = @import("std");
const LintId = @import("../lint.zig").LintId;
const PathKind = @import("../syntax/ast.zig").PathKind;

/// The lint a path literal triggers, if any. `lit` is the literal text
/// after the kind prefix.
pub fn pathLiteral(kind: PathKind, lit: []const u8) ?LintId {
    return switch (kind) {
        .absolute, .home => .absolute_path_literal,
        .relative => if (std.mem.startsWith(u8, lit, ".")) null else .short_path_literal,
        .search => null,
    };
}

/// Its message, in Nix's words, as a `{f}` argument.
pub const Message = struct {
    kind: PathKind,
    lit: []const u8,

    pub fn format(m: Message, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (m.kind) {
            .absolute => try w.print("absolute path literals are not portable. Consider replacing path literal '{s}' by a string, relative path, or parameter", .{m.lit}),
            .home => try w.print("home path literals are not portable. Consider replacing path literal '~{s}' by a string, relative path, or parameter", .{m.lit}),
            .relative => try w.print("relative path literal '{s}' should be prefixed with '.' for clarity: './{s}'", .{ m.lit, m.lit }),
            .search => {},
        }
    }
};
