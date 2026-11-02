//! Effects a helper fiber may not run yet: a lint finding it reached while
//! forcing ahead of demand.
//!
//! A helper parks an effect on the innermost thunk it is forcing; the thunk
//! is published `speculated_fx`, and its effects wait in `Pending` until
//! the demand path first takes that value, directly or through a thunk
//! that read it. So effects come out in the order of the sequential run,
//! and a finding from work the program never asks for is never seen: the
//! output is the same at any worker count.

const std = @import("std");
const Evaluator = @import("Evaluator.zig");
const lint_report = @import("../lint/report.zig");

/// One step of a thunk's effects, in the order its evaluation made it. A
/// `read` is the value of another speculated thunk with effects: those run
/// there, unless an earlier demand already ran them.
pub const Effect = union(enum) {
    run: *lint_report.Deferred,
    /// The address of the thunk's state cell.
    read: u64,

    fn drop(e: Effect, gpa: std.mem.Allocator) void {
        switch (e) {
            .run => |d| d.destroy(gpa),
            .read => {},
        }
    }
};

pub const Log = std.ArrayList(Effect);

/// A fiber's effect state: the effects of the thunks a helper is forcing,
/// innermost last, and how many thunks it is forcing. Inside one, a lint
/// finding waits on the demand of the innermost (`deferRun`).
pub const State = struct {
    log: Log = .empty,
    frames: u32 = 0,

    pub fn deinit(st: *State, gpa: std.mem.Allocator) void {
        for (st.log.items) |e| e.drop(gpa);
        st.log.deinit(gpa);
    }
};

/// Only a helper defers, and a helper always runs on a fiber; the
/// sequential path and the main fiber run every effect at once.
inline fn fiberOf(ev: *Evaluator) *State {
    return &ev.fiber.?.effects;
}

/// Effects held back, by thunk. Per pool, so a run that ends drops the
/// effects nothing took.
pub const Pending = struct {
    lock: std.Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(u64, Log) = .empty,

    pub fn deinit(p: *Pending, gpa: std.mem.Allocator) void {
        var it = p.map.valueIterator();
        while (it.next()) |l| {
            for (l.items) |e| e.drop(gpa);
            l.deinit(gpa);
        }
        p.map.deinit(gpa);
    }

    fn take(p: *Pending, io: std.Io, key: u64) ?Log {
        p.lock.lockUncancelable(io);
        defer p.lock.unlock(io);
        const kv = p.map.fetchRemove(key) orelse return null;
        return kv.value;
    }
};

/// Run an effect, or hold it back when a helper produced it inside a
/// thunk. Only for an effect the program may lose without losing anything
/// it returns.
pub fn deferRun(ev: *Evaluator, d: *lint_report.Deferred) void {
    if (ev.par.is_main or ev.fiber == null or fiberOf(ev).frames == 0) {
        d.run(ev);
        d.destroy(ev.gpa);
        return;
    }
    fiberOf(ev).log.append(ev.gpa, .{ .run = d }) catch d.destroy(ev.gpa);
}

/// Drop the effects past `mark`: the work that made them was given up.
pub fn truncate(ev: *Evaluator, mark: usize) void {
    const f = ev.fiber orelse return;
    if (f.effects.log.items.len <= mark) return;
    for (f.effects.log.items[mark..]) |e| e.drop(ev.gpa);
    f.effects.log.shrinkRetainingCapacity(mark);
}

/// A helper that cannot keep an effect gives up its work: every publish
/// it still makes becomes a reset, so the demand path evaluates the thunk
/// itself and runs the effect there. Nothing is lost, only redone.
fn giveUp(ev: *Evaluator) void {
    ev.par.cancelled = true;
}

/// Parks the effects a helper produced since `mark` on the thunk at `key`,
/// before its value is published. The thunk that forced it reads it.
pub noinline fn park(ev: *Evaluator, key: u64, mark: usize) void {
    const pool = ev.pool.?;
    var fx: Log = .empty;
    fx.appendSlice(ev.gpa, fiberOf(ev).log.items[mark..]) catch {
        truncate(ev, mark);
        return giveUp(ev);
    };
    fiberOf(ev).log.shrinkRetainingCapacity(mark);
    {
        pool.fx.lock.lockUncancelable(ev.io);
        defer pool.fx.lock.unlock(ev.io);
        const gop = pool.fx.map.getOrPut(ev.gpa, key) catch {
            for (fx.items) |e| e.drop(ev.gpa);
            fx.deinit(ev.gpa);
            return giveUp(ev);
        };
        // a thunk is published once per claim; a reset one may be forced
        // again, and both runs' effects are the same ones
        if (gop.found_existing) {
            for (gop.value_ptr.items) |e| e.drop(ev.gpa);
            gop.value_ptr.deinit(ev.gpa);
        }
        gop.value_ptr.* = fx;
    }
    if (fiberOf(ev).frames != 0) fiberOf(ev).log.append(ev.gpa, .{ .read = key }) catch giveUp(ev);
}

/// A fiber reads a value a helper computed with effects. The demand path
/// takes them now; a helper forcing a thunk notes the read, so the effects
/// come out where the demand path would have run them.
pub noinline fn readSpeculated(ev: *Evaluator, key: u64) void {
    if (ev.par.is_main) return release(ev, key);
    if (fiberOf(ev).frames != 0) fiberOf(ev).log.append(ev.gpa, .{ .read = key }) catch giveUp(ev);
}

/// The demand path took the value of the thunk at `key`: its effects, and
/// those of the thunks it read that nothing took before, are now the
/// program's.
fn release(ev: *Evaluator, key: u64) void {
    const pool = ev.pool orelse return;
    const first = pool.fx.take(ev.io, key) orelse return;
    var stack: std.ArrayList(struct { log: Log, i: usize }) = .empty;
    defer stack.deinit(ev.gpa);
    stack.append(ev.gpa, .{ .log = first, .i = 0 }) catch {
        dropLog(ev, first, 0);
        return;
    };
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.i == top.log.items.len) {
            var l = top.log;
            l.deinit(ev.gpa);
            _ = stack.pop();
            continue;
        }
        const e = top.log.items[top.i];
        top.i += 1;
        switch (e) {
            .run => |d| {
                d.run(ev);
                d.destroy(ev.gpa);
            },
            .read => |k| if (pool.fx.take(ev.io, k)) |next| {
                stack.append(ev.gpa, .{ .log = next, .i = 0 }) catch dropLog(ev, next, 0);
            },
        }
    }
}

fn dropLog(ev: *Evaluator, l: Log, from: usize) void {
    for (l.items[from..]) |e| e.drop(ev.gpa);
    var m = l;
    m.deinit(ev.gpa);
}
