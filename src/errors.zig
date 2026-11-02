//! The errors of everything outside the evaluator.
//! The evaluator keeps its own (`Evaluator.Failure`): an evaluation error
//! carries a source position and a trace. Here an error is one of the Zig
//! errors below, with its message (and hint) on a `Diag`.

const std = @import("std");
const Diag = @import("diag.zig").Diag;
const E = std.os.linux.E;

pub const Error = error{
    /// A file or a socket; the message is `context: strerror`.
    Io,
    /// Malformed data from another process: the nix-daemon worker protocol,
    /// a nix-eval-jobs line, `nix path-info`, a dev-env dump.
    Protocol,
    Plan,
    /// Store path, derivation or hash.
    Store,
    Flake,
    Cache,
    /// Something Nix does that iets does not: classic mode falls back on it.
    Unsupported,
    /// An evaluation error, reported by the evaluator's own report.
    Eval,
    /// Bad command-line input.
    Usage,
    /// nix.conf or iets.toml: a syntax error, a missing include, a bad value.
    Config,
};

/// The stable code of docs/reference/errors.md.
pub fn code(e: anyerror) []const u8 {
    return switch (e) {
        error.Io => "io",
        error.Protocol => "protocol",
        error.Plan => "plan",
        error.Store => "store",
        error.Flake => "flake",
        error.Cache => "cache",
        error.Unsupported => "unsupported",
        error.Eval => "eval",
        error.Usage => "usage",
        error.Config => "config",
        error.BadDerivation, error.BadStorePath, error.BadHash, error.BadJson => "store",
        else => "io",
    };
}

/// The report of an error outside the evaluator: its code, and the
/// message and hint on `d`.
pub fn report(e: anyerror, d: *const Diag) @import("log.zig").Report {
    return .{ .code = code(e), .raw = d.message(), .hint = d.hint };
}

/// The errno a Zig error stands for, when it is an OS error.
pub fn errnoOf(e: anyerror) ?E {
    return switch (e) {
        error.FileNotFound => .NOENT,
        error.AccessDenied, error.PermissionDenied => .ACCES,
        error.NotDir => .NOTDIR,
        error.IsDir => .ISDIR,
        error.NameTooLong => .NAMETOOLONG,
        error.SymLinkLoop => .LOOP,
        error.NoSpaceLeft => .NOSPC,
        error.ReadOnlyFileSystem => .ROFS,
        error.PathAlreadyExists => .EXIST,
        error.FileBusy => .TXTBSY,
        error.ProcessFdQuotaExceeded => .MFILE,
        error.SystemResources, error.OutOfMemory => .NOMEM,
        error.BrokenPipe => .PIPE,
        error.ConnectionRefused => .CONNREFUSED,
        error.ConnectionResetByPeer => .CONNRESET,
        error.ConnectionTimedOut, error.Timeout => .TIMEDOUT,
        error.NetworkUnreachable => .NETUNREACH,
        error.HostUnreachable => .HOSTUNREACH,
        error.AddressInUse => .ADDRINUSE,
        else => null,
    };
}

/// `strerror` of a raw errno.
pub fn errnoText(n: E) []const u8 {
    return switch (n) {
        .PERM => "Operation not permitted",
        .NOENT => "No such file or directory",
        .@"2BIG" => "Argument list too long",
        .NOEXEC => "Exec format error",
        .NOMEM => "Cannot allocate memory",
        .ACCES => "Permission denied",
        .EXIST => "File exists",
        .NOTDIR => "Not a directory",
        .ISDIR => "Is a directory",
        .MFILE => "Too many open files",
        .TXTBSY => "Text file busy",
        .NOSPC => "No space left on device",
        .ROFS => "Read-only file system",
        .PIPE => "Broken pipe",
        .NAMETOOLONG => "File name too long",
        .LOOP => "Too many levels of symbolic links",
        .NOTSOCK => "Socket operation on non-socket",
        .ADDRINUSE => "Address already in use",
        .NETUNREACH => "Network is unreachable",
        .CONNRESET => "Connection reset by peer",
        .TIMEDOUT => "Connection timed out",
        .CONNREFUSED => "Connection refused",
        .HOSTUNREACH => "No route to host",
        else => @tagName(n),
    };
}

/// `strerror` text, as Nix shows an OS error; the error's name for any
/// other.
pub fn ioText(e: anyerror) []const u8 {
    return if (errnoOf(e)) |n| errnoText(n) else @errorName(e);
}

/// An OS error as `text (os error N)`, the form Rust iets's messages print
/// it in, so iets's own messages read the same.
pub const Os = struct {
    e: anyerror,

    pub fn format(o: Os, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const n = errnoOf(o.e) orelse return w.writeAll(@errorName(o.e));
        return (OsErrno{ .n = n }).format(w);
    }
};

pub fn os(e: anyerror) Os {
    return .{ .e = e };
}

/// `os(e)` printed into `buf`, for a message that picks between texts.
pub fn osText(buf: []u8, e: anyerror) []const u8 {
    return std.fmt.bufPrint(buf, "{f}", .{os(e)}) catch ioText(e);
}

/// A raw errno in the same `text (os error N)` form.
pub const OsErrno = struct {
    n: E,

    pub fn format(o: OsErrno, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} (os error {d})", .{ errnoText(o.n), @backingInt(o.n) });
    }
};

pub fn osErrno(n: E) OsErrno {
    return .{ .n = n };
}

/// Records an I/O error: `context: strerror`, or the text alone.
pub fn io(d: *Diag, context: []const u8, e: anyerror) Error {
    if (context.len == 0) return d.fail(error.Io, "{s}", .{ioText(e)});
    return d.fail(error.Io, "{s}: {s}", .{ context, ioText(e) });
}

test "codes and texts" {
    try std.testing.expectEqualStrings("config", code(error.Config));
    try std.testing.expectEqualStrings("usage", code(error.Usage));
    try std.testing.expectEqualStrings("No such file or directory", ioText(error.FileNotFound));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Permission denied (os error 13)", try std.fmt.bufPrint(&buf, "{f}", .{os(error.AccessDenied)}));
    try std.testing.expectEqualStrings("Exec format error (os error 8)", try std.fmt.bufPrint(&buf, "{f}", .{osErrno(.NOEXEC)}));
    try std.testing.expectEqualStrings("Bogus", try std.fmt.bufPrint(&buf, "{f}", .{os(error.Bogus)}));
    var d: Diag = .init(std.testing.allocator);
    defer d.deinit();
    try std.testing.expectEqual(error.Io, io(&d, "opening x", error.FileNotFound));
    try std.testing.expectEqualStrings("opening x: No such file or directory", d.message());
    try std.testing.expectEqual(error.Usage, d.failHint(error.Usage, "use -E", "bad {s}", .{"flag"}));
    try std.testing.expectEqualStrings("bad flag", d.message());
    try std.testing.expectEqualStrings("use -E", d.hint.?);
}
