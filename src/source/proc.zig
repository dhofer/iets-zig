//! Running a child with its input piped in and its output read back, for
//! the commands of an SCM that no observation records (`git cat-file
//! --batch`, `git check-attr --stdin`) and the fetch through the real nix.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Output = struct {
    status: i32,
    stdout: []u8,

    pub fn deinit(o: Output, gpa: Allocator) void {
        gpa.free(o.stdout);
    }
};

/// The environment of this process, for a child that needs one more
/// variable and has no session to take the environment from.
pub fn processEnv(a: Allocator) Allocator.Error!std.process.Environ.Map {
    const raw: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const env: std.process.Environ = .{ .block = .{ .slice = std.mem.span(raw) } };
    return env.createMap(a) catch return error.OutOfMemory;
}

/// Runs `argv` in `dir` (the current directory when null), `stdin` as its
/// input (none when null) and `env` as its environment (inherited when
/// null); stderr is inherited.
pub fn run(gpa: Allocator, io: Io, dir: ?[]const u8, argv: []const []const u8, stdin: ?[]const u8, env: ?*const std.process.Environ.Map) !Output {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (dir) |d| .{ .path = d } else .inherit,
        .environ_map = env,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);
    // the input goes in on a thread of its own, so a child that answers as
    // it reads never blocks on a full stdout pipe
    var writer: ?std.Thread = null;
    if (stdin) |bytes| {
        const W = struct {
            fn go(i: Io, f: Io.File, b: []const u8) void {
                f.writeStreamingAll(i, b) catch {};
                f.close(i);
            }
        };
        const f = child.stdin.?;
        child.stdin = null;
        writer = try std.Thread.spawn(.{}, W.go, .{ io, f, bytes });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 << 10]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &.{});
    while (true) {
        const n = r.interface.readSliceShort(&buf) catch break;
        if (n == 0) break;
        try out.appendSlice(gpa, buf[0..n]);
    }
    if (writer) |w| w.join();
    const term = try child.wait(io);
    const status: i32 = switch (term) {
        .exited => |c| c,
        else => -1,
    };
    return .{ .status = status, .stdout = try out.toOwnedSlice(gpa) };
}

test "a command runs in its directory with its input" {
    const gpa = std.testing.allocator;
    const o = try run(gpa, std.testing.io, "/", &.{ "sh", "-c", "pwd; exit 3" }, null, null);
    defer o.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 3), o.status);
    try std.testing.expectEqualStrings("/\n", o.stdout);
    const p = try run(gpa, std.testing.io, null, &.{"cat"}, "piped in", null);
    defer p.deinit(gpa);
    try std.testing.expectEqualStrings("piped in", p.stdout);
}
