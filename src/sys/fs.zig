//! File modes, symlinks and locks, as much as the outer layers need. Linux
//! only; Windows is not supported.

const std = @import("std");
const linux = std.os.linux;

/// The type and mode bits of `path`, following a final symlink when
/// `follow`; null when it cannot be read.
pub fn mode(path: []const u8, follow: bool) ?u16 {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(linux.AT.FDCWD, buf[0..path.len :0], flags, .{ .TYPE = true, .MODE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return st.mode;
}

/// What a `stat` reports that the tracing cache keeps: the kind, the size,
/// both times in nanoseconds, the device and inode, and the mode bits.
/// `std.Io.File.Stat` has no device, which an observation needs: the same
/// inode number on another file system is another file.
pub const Meta = struct {
    mode: u16,
    size: u64,
    mtime_ns: i64,
    mtime_secs: i64,
    ctime_ns: i64,
    dev: u64,
    ino: u64,

    fn of(st: *const linux.Statx) Meta {
        return .{
            .mode = st.mode,
            .size = st.size,
            .mtime_ns = st.mtime.sec *% 1_000_000_000 +% st.mtime.nsec,
            .mtime_secs = st.mtime.sec,
            .ctime_ns = st.ctime.sec *% 1_000_000_000 +% st.ctime.nsec,
            .dev = makedev(st.dev_major, st.dev_minor),
            .ino = st.ino,
        };
    }

    pub fn isFile(m: Meta) bool {
        return isFileMode(m.mode);
    }

    pub fn isDir(m: Meta) bool {
        return isDirMode(m.mode);
    }

    pub fn isSymlink(m: Meta) bool {
        return m.mode & linux.S.IFMT == linux.S.IFLNK;
    }
};

/// glibc's `makedev`: the `st_dev` that `stat` reports.
fn makedev(major: u32, minor: u32) u64 {
    const ma: u64 = major;
    const mi: u64 = minor;
    return ((ma & 0xfffff000) << 32) | ((ma & 0xfff) << 8) | ((mi & 0xffffff00) << 12) | (mi & 0xff);
}

const stat_mask: linux.STATX = .{ .TYPE = true, .MODE = true, .INO = true, .SIZE = true, .MTIME = true, .CTIME = true };

/// What a failed `stat` says: the path is not there, a component is no
/// directory, or anything else.
pub const StatError = error{ FileNotFound, NotDir, NameTooLong, AccessDenied, SymLinkLoop, Unreadable };

fn statError(e: linux.E) StatError {
    return switch (e) {
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .NAMETOOLONG => error.NameTooLong,
        .ACCES, .PERM => error.AccessDenied,
        .LOOP => error.SymLinkLoop,
        else => error.Unreadable,
    };
}

/// `stat`, or `lstat` unless `follow`.
pub fn stat(path: []const u8, follow: bool) StatError!Meta {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var st: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const rc = linux.statx(linux.AT.FDCWD, buf[0..path.len :0], flags, stat_mask, &st);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return statError(e);
    return .of(&st);
}

/// `fstat` of an open file.
pub fn fstat(fd: linux.fd_t) StatError!Meta {
    var st: linux.Statx = undefined;
    const rc = linux.statx(fd, "", 0x1000, stat_mask, &st);
    const e = linux.errno(rc);
    if (e != .SUCCESS) return statError(e);
    return .of(&st);
}

pub fn isFileMode(m: u16) bool {
    return m & linux.S.IFMT == linux.S.IFREG;
}

pub fn isDirMode(m: u16) bool {
    return m & linux.S.IFMT == linux.S.IFDIR;
}

pub fn isFile(m: u16) bool {
    return m & linux.S.IFMT == linux.S.IFREG;
}

pub fn isDir(m: u16) bool {
    return m & linux.S.IFMT == linux.S.IFDIR;
}

pub fn isSocket(m: u16) bool {
    return m & linux.S.IFMT == linux.S.IFSOCK;
}

/// Owner execute bit, which is what a NAR calls executable.
pub fn isExecutable(m: u16) bool {
    return m & 0o100 != 0;
}

/// Any execute bit, which is what a lookup in `PATH` needs.
pub fn isRunnable(m: u16) bool {
    return m & 0o111 != 0;
}

/// A regular file with an execute bit, after following links.
pub fn runnableFile(path: []const u8) bool {
    const m = mode(path, true) orelse return false;
    return isFile(m) and isRunnable(m);
}

pub fn exists(path: []const u8) bool {
    return mode(path, true) != null;
}

/// Takes an exclusive lock on `fd` if nobody holds it.
pub fn tryLock(fd: linux.fd_t) bool {
    return linux.errno(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB)) == .SUCCESS;
}

/// Takes an exclusive lock on `fd`, waiting for it. `false` on a real error.
pub fn lock(fd: linux.fd_t) bool {
    while (true) switch (linux.errno(linux.flock(fd, std.posix.LOCK.EX))) {
        .SUCCESS => return true,
        .INTR => {},
        else => return false,
    };
}

pub fn unlock(fd: linux.fd_t) void {
    _ = linux.flock(fd, std.posix.LOCK.UN);
}

/// Writes all of `bytes` to `fd`, retrying on a short write or a signal.
pub fn writeAll(fd: linux.fd_t, bytes: []const u8) error{WriteFailed}!void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => rest = rest[rc..],
            .INTR, .AGAIN => {},
            else => return error.WriteFailed,
        }
    }
}

test "modes" {
    const m = mode("/", true).?;
    try std.testing.expect(isDir(m) and !isFile(m) and !isSocket(m));
    try std.testing.expect(mode("/nonexistent/x", true) == null);
    try std.testing.expect(isRunnable(0o001) and !isExecutable(0o011) and isExecutable(0o100));
}

/// An unbuffered `std.Io.Writer` onto a file descriptor, for a sink that
/// any thread may write to without an `Io`: a log file, an events socket.
pub const FdWriter = struct {
    fd: linux.fd_t,
    interface: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @fieldParentPtr("interface", w);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            writeAll(self.fd, d) catch return error.WriteFailed;
            n += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            writeAll(self.fd, last) catch return error.WriteFailed;
            n += last.len;
        }
        return n;
    }

    pub fn close(self: *FdWriter) void {
        _ = linux.close(self.fd);
    }
};

/// `path` opened to append to, created with mode 0644; a unix socket is
/// connected to instead.
pub fn openSink(path: []const u8) union(enum) { fd: linux.fd_t, err: linux.E } {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return .{ .err = .NAMETOOLONG };
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const z = buf[0..path.len :0];
    if (mode(path, true)) |m| if (isSocket(m)) {
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return .{ .err = linux.errno(rc) };
        const fd: linux.fd_t = @intCast(rc);
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len >= addr.path.len) {
            _ = linux.close(fd);
            return .{ .err = .NAMETOOLONG };
        }
        @memcpy(addr.path[0..path.len], path);
        const c = linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un));
        if (linux.errno(c) != .SUCCESS) {
            _ = linux.close(fd);
            return .{ .err = linux.errno(c) };
        }
        return .{ .fd = fd };
    };
    const rc = linux.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o644);
    if (linux.errno(rc) != .SUCCESS) return .{ .err = linux.errno(rc) };
    return .{ .fd = @intCast(rc) };
}

/// Whether resolving `rel` in the directory `root` provably stays below it:
/// true when it opened there, false when it stopped at a missing entry,
/// which no read gets past either; null when the kernel cannot say
/// (`openat2` is Linux 5.6).
pub fn beneath(root: linux.fd_t, rel: []const u8, follow: bool) ?bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = if (rel.len == 0) "." else rel;
    if (r.len >= buf.len) return null;
    @memcpy(buf[0..r.len], r);
    buf[r.len] = 0;
    const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
    var flags: linux.O = .{ .PATH = true, .CLOEXEC = true };
    if (!follow) flags.NOFOLLOW = true;
    const resolve_beneath: u64 = 0x08;
    const resolve_no_magiclinks: u64 = 0x02;
    var how: OpenHow = .{ .flags = @as(u32, @bitCast(flags)), .mode = 0, .resolve = resolve_beneath | resolve_no_magiclinks };
    const rc = linux.syscall4(.openat2, @bitCast(@as(isize, root)), @intFromPtr(&buf), @intFromPtr(&how), @sizeOf(OpenHow));
    switch (linux.errno(rc)) {
        .SUCCESS => {
            _ = linux.close(@intCast(rc));
            return true;
        },
        .NOENT, .NOTDIR => return false,
        else => return null,
    }
}

test "beneath stays below its root" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "r/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "r/sub/f", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "out", .data = "x" });
    try tmp.dir.symLink(io, "../out", "r/link", .{});
    const r = try tmp.dir.openDir(io, "r", .{});
    defer r.close(io);
    const fd = r.handle;
    if (beneath(fd, "sub/f", true) == null) return; // no openat2 here
    try std.testing.expectEqual(@as(?bool, true), beneath(fd, "sub/f", true));
    try std.testing.expectEqual(@as(?bool, false), beneath(fd, "missing", true));
    try std.testing.expectEqual(@as(?bool, null), beneath(fd, "link", true));
    try std.testing.expectEqual(@as(?bool, true), beneath(fd, "link", false));
    try std.testing.expectEqual(@as(?bool, null), beneath(fd, "../out", true));
}

/// Starts writing `len` bytes of `fd` at `off` to disk without waiting
/// (`sync_file_range` with `SYNC_FILE_RANGE_WRITE`), so a later `fsync`
/// finds them on their way. A hint: a failure only leaves the work to it.
pub fn startWriteback(fd: linux.fd_t, off: u64, len: u64) void {
    const write: usize = 2;
    _ = linux.syscall4(.sync_file_range, @bitCast(@as(isize, fd)), off, len, write);
}
