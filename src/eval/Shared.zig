//! The state every worker's evaluator shares: the tables a builtin fills as
//! a side of evaluation. Each sits behind its own lock; a worker's arena,
//! strings and statistics stay its own.

const std = @import("std");
const Shared = @This();
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Evaluator = @import("Evaluator.zig");
const derivation = @import("../builtins/derivation.zig");
const store_hooks = @import("../builtins/store_hooks.zig");
const lint_report = @import("../lint/report.zig");

/// The derivations this evaluation made (`builtins/derivation.zig`).
drv: derivation.State = .{},
drv_lock: RecursiveLock = .{},
/// Store paths this evaluation made and what they stand for (`builtins/store_hooks.zig`).
hooks: store_hooks.State = .{},
hooks_lock: std.Io.Mutex = .init,
/// Imported files by resolved path: one import thunk each, so a file is
/// compiled and evaluated once whichever thread asks first.
imports: std.StringHashMapUnmanaged(Value) = .empty,
imports_lock: std.Io.Mutex = .init,
/// What a `prefetch` task runs: the eval-jobs walk's look-ahead
/// (`jobs.zig`). Set before the first such task is submitted.
prefetch: ?Prefetch = null,
/// The lint warnings this run emitted (`lint/report.zig`), with their lock.
lints: lint_report.Emitted = .{},
/// The lock's node name of each locked input, by the `narHash` the lock
/// gives it, for messages and the lint scope.
input_names: std.StringHashMapUnmanaged([]const u8) = .empty,
input_names_lock: std.Io.Mutex = .init,
/// The eval store's connections (`source/remote.zig`).
daemon: @import("../source/remote.zig").Daemon = .{},
/// The flakes this run loaded (`api/flake.zig`).
flakes: @import("../api/flake.zig").Loaded = .{},

/// `f(ctx, ev, attrs, start, end)` forces what the walk will ask of
/// `attrs`' cells `start..end`; it never parks on a cell another fiber holds.
pub const Prefetch = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, ev: *Evaluator, attrs: *value.Attrs, start: u32, end: u32) void,
};

pub fn deinit(s: *Shared, gpa: std.mem.Allocator) void {
    s.drv.deinit(gpa);
    s.imports.deinit(gpa);
    s.hooks.deinit(gpa);
    s.lints.deinit(gpa);
    s.input_names.deinit(gpa);
    s.daemon.deinit(gpa);
    s.flakes.deinit(gpa);
}

/// A mutex its holder may take again: the derivation code reads the table
/// both from a builtin and from the loader that builtin calls. The holder is
/// an evaluator, one per fiber, never a thread: a fiber that parks may
/// resume on another thread, and another fiber may run on this one.
pub const RecursiveLock = struct {
    m: std.Io.Mutex = .init,
    owner: std.atomic.Value(?*const Evaluator) = .init(null),
    depth: u32 = 0,

    pub fn lock(l: *RecursiveLock, ev: *const Evaluator) void {
        if (l.owner.load(.monotonic) == ev) {
            l.depth += 1;
            return;
        }
        l.m.lockUncancelable(ev.io);
        l.owner.store(ev, .monotonic);
        l.depth = 1;
    }

    pub fn unlock(l: *RecursiveLock, ev: *const Evaluator) void {
        l.depth -= 1;
        if (l.depth > 0) return;
        l.owner.store(null, .monotonic);
        l.m.unlock(ev.io);
    }
};
