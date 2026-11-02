//! The URL-literal lint Nix has (`lint-url-literals`), with Nix's messages.
//! Hooks: the parser notes a URL literal; the compiler reports it.

const std = @import("std");

/// The message, as a `{f}` argument.
pub const UrlLiteral = struct {
    text: []const u8,
    is_error: bool,

    pub fn format(u: UrlLiteral, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("URL literals are {s}. Consider using a string literal \"{s}\" instead", .{ if (u.is_error) "disallowed" else "discouraged", u.text });
    }
};
