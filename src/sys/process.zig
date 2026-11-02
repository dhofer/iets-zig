//! Replacing the process image and reading how a child ended. Linux only.

const std = @import("std");
const linux = std.os.linux;

/// Runs `path` with `argv` in place of this process, `argv[0]` naming it.
/// Returns only on failure, with the errno.
pub fn exec(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) linux.E {
    return linux.errno(linux.execve(path, argv, envp));
}

/// The process environment as it is now, `setenv` included.
pub fn environ() [*:null]const ?[*:0]const u8 {
    return @ptrCast(std.c.environ);
}

/// `file` with `argv` (`argv[0]` naming it) and `envp` in place of this
/// process: a name without a slash is looked up
/// in `path`, else in this process's `PATH`. Returns only on failure.
pub fn execvpe(a: std.mem.Allocator, file: []const u8, argv: []const []const u8, envp: [*:null]const ?[*:0]const u8, path: ?[]const u8) linux.E {
    const zargv = a.allocSentinel(?[*:0]const u8, argv.len, null) catch return .NOMEM;
    for (argv, zargv) |x, *z| z.* = (a.dupeSentinel(u8, x, 0) catch return .NOMEM).ptr;
    if (std.mem.indexOfScalar(u8, file, '/') != null) {
        const zf = a.dupeSentinel(u8, file, 0) catch return .NOMEM;
        return exec(zf, zargv, envp);
    }
    const search = path orelse if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/bin:/usr/bin";
    var err: linux.E = .NOENT;
    var it = std.mem.splitScalar(u8, search, ':');
    while (it.next()) |dir| {
        const full = std.fmt.allocPrintSentinel(a, "{s}{s}{s}", .{ dir, if (dir.len == 0 or dir[dir.len - 1] == '/') "" else "/", file }, 0) catch return .NOMEM;
        const e = exec(full, zargv, envp);
        // execvp's rule: an entry that is not there is no answer, a
        // refused one is remembered
        switch (e) {
            .NOENT, .NOTDIR => {},
            .ACCES => err = .ACCES,
            else => return e,
        }
    }
    return err;
}

/// The signal that ended a child, from its wait status; null when it
/// exited.
pub fn signal(status: u32) ?u32 {
    const sig = status & 0x7f;
    if (sig == 0 or sig == 0x7f) return null;
    return sig;
}

test "a wait status names its signal" {
    try std.testing.expectEqual(@as(?u32, null), signal(1 << 8));
    try std.testing.expectEqual(@as(?u32, 9), signal(9));
    try std.testing.expectEqual(@as(?u32, 15), signal(15 | 0x80));
}
