//! Turning a fault on a known address into a message and an exit. Linux
//! only. The fiber pool installs it to name a guard-page hit a stack
//! overflow (`eval/Pool.zig`).
//!
//! Before that, a thread that registered its guard (`guardThread`) gets
//! what Rust iets prints for a thread's overflow: the "has overflowed its
//! stack" line and an abort. The pool's `install` replaces that handler.

const std = @import("std");
const linux = std.os.linux;

/// What to do about a fault that belongs to this process.
pub const Fault = struct {
    message: []const u8,
    /// Abort for a core dump, or exit with status 1.
    abort: bool,
};

/// Gets the faulting address and a buffer for a message it formats; runs
/// inside the handler, so it must not lock or allocate.
pub const Classify = *const fn (addr: usize, buf: []u8) ?Fault;

var classify_fn: std.atomic.Value(?Classify) = .init(null);
var installed: std.atomic.Value(bool) = .init(false);

/// Replaces the runtime's fault handler. A fault `classify` declines gets
/// the default disposition.
pub fn install(classify: Classify) void {
    classify_fn.store(classify, .release);
    if (installed.swap(true, .acq_rel)) return;
    for ([_]linux.SIG{ .SEGV, .BUS }) |sig| {
        const act: linux.Sigaction = .{
            .handler = .{ .sigaction = onFault },
            .mask = linux.sigemptyset(),
            .flags = linux.SA.ONSTACK | linux.SA.SIGINFO,
        };
        _ = linux.sigaction(sig, &act, null);
    }
}

fn onFault(sig: linux.SIG, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const addr = @intFromPtr(info.fields.sigfault.addr);
    var buf: [160]u8 = undefined;
    if (classify_fn.load(.acquire)) |c| if (c(addr, &buf)) |f| {
        _ = linux.write(2, f.message.ptr, f.message.len);
        if (f.abort) std.c.abort();
        linux.exit_group(1);
    };
    // not ours: let the default disposition produce the usual crash
    const dfl: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(sig, &dfl, null);
}

/// Bytes of an alternate signal stack: the handler's frame and a message.
pub const alt_size = 64 << 10;

/// Sets this thread's alternate signal stack, so a fault caused by an
/// exhausted stack can still be reported, and returns the one it had. It
/// must lie outside every stack it serves; a buffer at the top of a big
/// thread stack does for that thread. Give the old one back with
/// `restoreAltStack` before the memory goes.
pub fn altStack(buf: []align(16) u8) linux.stack_t {
    const ss: linux.stack_t = .{ .sp = buf.ptr, .flags = 0, .size = buf.len };
    var old: linux.stack_t = undefined;
    if (linux.errno(linux.sigaltstack(&ss, &old)) != .SUCCESS) old = .{ .sp = undefined, .flags = linux.SS.DISABLE, .size = 0 };
    return old;
}

pub fn restoreAltStack(old: linux.stack_t) void {
    _ = linux.sigaltstack(&old, null);
}

// The runtime-style handler, with the message and abort Rust iets prints,
// for the evaluator thread of a one-worker run, which otherwise has none.

const max_threads = 16;
var thread_guards: [max_threads]struct { lo: std.atomic.Value(usize) = .init(0), hi: std.atomic.Value(usize) = .init(0) } = @splat(.{});

extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) std.c.E;
extern "c" fn pthread_attr_getstack(attr: *const std.c.pthread_attr_t, addr: *?*anyopaque, size: *usize) std.c.E;
extern "c" fn pthread_attr_getguardsize(attr: *const std.c.pthread_attr_t, size: *usize) std.c.E;

/// Registers the calling thread's guard page, `[start - guard, start +
/// guard)`, and
/// returns a token for `unguardThread`. Installs the runtime-style handler
/// unless one is installed already.
pub fn guardThread() ?usize {
    var attr: std.c.pthread_attr_t = undefined;
    if (pthread_getattr_np(std.c.pthread_self(), &attr) != .SUCCESS) return null;
    defer _ = std.c.pthread_attr_destroy(&attr);
    var addr: ?*anyopaque = null;
    var size: usize = 0;
    var guard: usize = 0;
    if (pthread_attr_getstack(&attr, &addr, &size) != .SUCCESS) return null;
    if (pthread_attr_getguardsize(&attr, &guard) != .SUCCESS or guard == 0) return null;
    const start = @intFromPtr(addr);
    for (&thread_guards, 0..) |*g, i| {
        if (g.lo.cmpxchgStrong(0, start - guard, .acq_rel, .monotonic) == null) {
            g.hi.store(start + guard, .release);
            if (!installed.load(.acquire)) install(runtimeClassify);
            return i;
        }
    }
    return null;
}

pub fn unguardThread(token: ?usize) void {
    const i = token orelse return;
    thread_guards[i].hi.store(0, .release);
    thread_guards[i].lo.store(0, .release);
}

fn runtimeClassify(addr: usize, buf: []u8) ?Fault {
    for (&thread_guards) |*g| {
        const lo = g.lo.load(.acquire);
        if (lo != 0 and addr >= lo and addr < g.hi.load(.acquire)) {
            const msg = std.fmt.bufPrint(buf, "\nthread '<unknown>' ({d}) has overflowed its stack\nfatal runtime error: stack overflow, aborting\n", .{linux.gettid()}) catch return null;
            return .{ .message = msg, .abort = true };
        }
    }
    return null;
}

test "the handler and the alternate stack compile" {
    // installing it here would replace the test runner's own handler
    _ = &install;
    _ = &onFault;
    _ = &guardThread;
    var stack: [alt_size]u8 align(16) = undefined;
    restoreAltStack(altStack(&stack));
}

test "the runtime's message names the thread" {
    var buf: [160]u8 = undefined;
    thread_guards[max_threads - 1].lo.store(0x1000, .release);
    thread_guards[max_threads - 1].hi.store(0x3000, .release);
    defer unguardThread(max_threads - 1);
    const f = runtimeClassify(0x2000, &buf).?;
    try std.testing.expect(f.abort);
    try std.testing.expect(std.mem.startsWith(u8, f.message, "\nthread '<unknown>' ("));
    try std.testing.expect(runtimeClassify(0x4000, &buf) == null);
}
