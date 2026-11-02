//! Parallel evaluation: fibers on worker threads, work-stealing lanes, and
//! the wait side of the thunk claim protocol. The design and its
//! measurements are in ../iets/docs/explanation/evaluation.md.
//!
//! The command's own evaluation is the main fiber. A strict consumer offers
//! the cells it is about to walk as tasks on its worker's lane; idle workers
//! steal them and run each in a helper fiber, which forces the cells ahead
//! of the demand path. A fiber that meets a thunk another fiber holds parks
//! on it in a waiter table and its thread runs other work; the holder wakes
//! it when it publishes. Fibers move between threads, so a fiber's evaluator
//! borrows the `Local` of the worker running it, and nothing on these paths
//! reads a thread-local.
//!
//! Fiber states:
//!
//!   new/runnable --resume--> running --finish--> finished
//!                               |
//!                            parking --switch out--> suspended --wake--> runnable
//!                               |
//!                       wake before switch-out: woken --> runnable (by its old worker)
//!
//! A waker never queues a fiber still on its stack: it moves `parking` to
//! `woken`, and the worker that switched the fiber out queues it.

const std = @import("std");
const Pool = @This();
const Atomic = std.atomic.Value;
const Evaluator = @import("Evaluator.zig");
const Deque = @import("Deque.zig");
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Cell = value.Cell;
const Interner = @import("../syntax/symbol.zig").Interner;
const fiber_ctx = std.Io.fiber;
const fault = @import("../sys/fault.zig");

gpa: std.mem.Allocator,
io: std.Io,
main: *Evaluator,
workers: []Worker,
lanes: []Lanes,
overflow_lock: std.Io.Mutex = .init,
overflow: std.ArrayList(*Fiber) = .empty,
overflow_len: Atomic(usize) align(std.atomic.cache_line) = .init(0),
/// Summaries of queued work, so an idle worker polls two words instead of
/// every lane's deque lines.
pending_tasks: Atomic(usize) align(std.atomic.cache_line) = .init(0),
pending_ready: Atomic(usize) align(std.atomic.cache_line) = .init(0),
/// Idle workers searching for work. A push wakes a sleeper only when none
/// searches: a searcher finds the work, and when it takes it, it wakes one
/// more sleeper if work remains, one wake per handoff, never one per push.
spinners: Atomic(usize) align(std.atomic.cache_line) = .init(0),
sleepers: Atomic(usize) align(std.atomic.cache_line) = .init(0),
epoch: Atomic(u32) align(std.atomic.cache_line) = .init(0),
main_done: Atomic(bool) = .init(false),
next_id: Atomic(u32) = .init(1),
all_lock: std.Io.Mutex = .init,
all: std.ArrayList(*Fiber) = .empty,
waiters: [64]Shard = @splat(.{}),
/// Thunks whose evaluation failed in a helper, for helpers to skip. A
/// failure is not memoised (Nix evaluates a failed thunk again at every
/// force), so this only stops the speculation: every cell of a fan-out
/// would otherwise start the same failing computation again.
failed: [256]Atomic(u64) = @splat(.init(0)),
any_failed: Atomic(bool) = .init(false),
/// Effects held back by helpers (`effects.zig`), by thunk: per pool, so a
/// run that ends drops the effects nothing took.
fx: @import("effects.zig").Pending = .{},
tune: Tuning,
stats: Stats = .{},
/// What the helpers counted, added when each finishes a task, so a stats
/// line reports the run and not only the demand path. Only a stats run
/// folds anything.
totals: Totals = .{},
fold: bool = false,

pub const Totals = struct {
    thunks: Atomic(u64) = .init(0),
    calls: Atomic(u64) = .init(0),
    store_adds: Atomic(u64) = .init(0),
    compile_ns: Atomic(u64) = .init(0),

    fn add(t: *Totals, s: *Evaluator.Stats) void {
        _ = t.thunks.fetchAdd(s.thunks, .monotonic);
        _ = t.calls.fetchAdd(s.calls, .monotonic);
        _ = t.store_adds.fetchAdd(s.store_adds, .monotonic);
        _ = t.compile_ns.fetchAdd(s.compile_ns, .monotonic);
        s.* = .{};
    }
};

/// The arena bytes handed out and mapped, summed over every worker: each
/// allocates from its own arena, so only the sum is the run's memory. A
/// worker allocating right now may be a little ahead of what this reads.
pub fn arenaUse(pool: *const Pool) struct { bytes: u64, mapped: u64 } {
    var bytes: u64 = 0;
    var mapped: u64 = 0;
    for (pool.workers) |*w| {
        bytes += @atomicLoad(usize, &w.local.arena.used, .monotonic);
        mapped += @atomicLoad(usize, &w.local.arena.mapped, .monotonic);
    }
    return .{ .bytes = bytes, .mapped = mapped };
}

pub const Stats = struct {
    tasks: Atomic(u64) = .init(0),
    steals: Atomic(u64) = .init(0),
    parks: Atomic(u64) = .init(0),
    main_parks: Atomic(u64) = .init(0),
    main_wait_ns: Atomic(u64) = .init(0),
    deadlocks: Atomic(u64) = .init(0),
    fibers: Atomic(u64) = .init(0),
    wakes: Atomic(u64) = .init(0),
    sleeps: Atomic(u64) = .init(0),

    pub fn format(s: *const Stats, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("tasks {d}, steals {d}, parks {d}, main parked {d} times for {d} ms, deadlocks {d}, fibers {d}, wakes {d}, sleeps {d}", .{
            s.tasks.load(.monotonic),      s.steals.load(.monotonic),                            s.parks.load(.monotonic),
            s.main_parks.load(.monotonic), s.main_wait_ns.load(.monotonic) / std.time.ns_per_ms, s.deadlocks.load(.monotonic),
            s.fibers.load(.monotonic),     s.wakes.load(.monotonic),                             s.sleeps.load(.monotonic),
        });
    }
};

const Tuning = struct {
    /// Scans of 64 polls an idle searcher makes before it parks (about 2 ms).
    spin: u32 = 2000,
    /// Queued tasks per awake worker that justify waking one more sleeper.
    handoff: usize = 8,
    /// Idle workers allowed to search at once.
    spinner_cap: usize,
};

const ready_cap = 4096;
const task_cap = 4096;
const helper_stack = 256 << 20;
pub const main_stack = 4 << 30;
/// A helper that comes this close to the end of its stack gives up its task.
const stack_margin = 1 << 20;
/// Polls of a busy thunk's state before a fiber parks on it.
const wait_spin = 256;

const Lanes = struct {
    ready: Deque,
    tasks: Deque,
};

pub const Worker = struct {
    idx: usize,
    pool: *Pool,
    thread: ?std.Thread = null,
    local: Evaluator.Local,
    interner: Interner,
    /// This thread's own context, where a running fiber switches back to.
    ctx: fiber_ctx.Context = undefined,
    /// Idle fibers with their stacks, for the next task.
    idle: std.ArrayList(*Fiber) = .empty,
    /// Times this worker went to sleep, which paces `trimIdle`.
    sleeps: u32 = 0,
    spinning: bool = false,
    rng: u64,

    fn nextVictim(w: *Worker) usize {
        w.rng ^= w.rng << 13;
        w.rng ^= w.rng >> 7;
        w.rng ^= w.rng << 17;
        return @intCast(w.rng >> 32);
    }
};

pub const State = enum(u8) { new, running, parking, woken, suspended, runnable, finished };

/// A stackful coroutine and the evaluator it runs.
pub const Fiber = struct {
    ctx: fiber_ctx.Context = undefined,
    stack: []align(std.heap.page_size_min) u8,
    pool: *Pool,
    state: Atomic(State) = .init(.new),
    /// Claimer id: nonzero, unique, stable across migration.
    id: u32,
    is_main: bool = false,
    /// Set by deadlock resolution: the fiber must stop.
    cancel: Atomic(bool) = .init(false),
    task: Task = undefined,
    main_job: ?struct { f: *const fn (*Evaluator, *anyopaque) void, ctx: *anyopaque } = null,
    /// The worker running this fiber; valid while `running`.
    worker: *Worker = undefined,
    /// A helper's own evaluator; the main fiber runs the main one.
    own: Evaluator = undefined,
    /// The effects a helper holds back (`effects.zig`).
    effects: @import("effects.zig").State = .{},
    ev: *Evaluator = undefined,
    /// The stack below its warm top went back to the kernel while idle.
    trimmed: bool = false,

    /// The lowest stack address a helper may reach before it gives up.
    pub fn stackLimit(f: *const Fiber) usize {
        return @intFromPtr(f.stack.ptr) + std.heap.page_size_min + stack_margin;
    }

    /// Switch back to the worker. Never inlined: inlined deep into the
    /// force path, the switch's `rsi` input went unset in an optimised
    /// build (Zig 0.17).
    noinline fn yield(f: *Fiber) void {
        var sw: fiber_ctx.Switch = .{ .old = &f.ctx, .new = &f.worker.ctx };
        _ = fiber_ctx.contextSwitch(&sw);
    }
};

/// A range of cells: a list's elements or a set's attribute values.
pub const Task = struct {
    kind: Kind,
    obj: Value,
    start: u32,
    len: u32,

    pub const Kind = enum(u8) {
        /// Force each cell: what a strict list builtin will do.
        list_whnf,
        /// Force each attribute: what a walk over a set's children (the
        /// `search` index) will do.
        attrs_whnf,
        /// Force and walk each cell as `deepSeq` will.
        list_deep,
        attrs_deep,
        /// Force and walk each cell as a coercion to string will: lists
        /// element-wise, derivations to `outPath`, other sets attribute-wise.
        /// What `derivationStrict`, `toJSON` and `concatStringsSep` demand.
        list_coerce,
        attrs_coerce,
        /// Job `start` of the `Evaluator.Jobs` at `obj`'s address.
        job,
        /// The eval-jobs walk forcing ahead what it will ask of the
        /// attributes in the range (`Shared.prefetch`).
        prefetch,
    };

    /// 8 bits of kind, 32 of start, 16 of len: a range is at most one batch.
    fn pack(t: Task) Deque.Entry {
        return .{ t.obj.bits(), @as(u64, @backingInt(t.kind)) | @as(u64, t.start) << 8 | @as(u64, t.len) << 40 };
    }

    fn unpack(e: Deque.Entry) Task {
        return .{ .obj = @fromBackingInt(@intCast(e[0])), .kind = @fromBackingInt(@intCast(@as(u8, @truncate(e[1])))), .start = @truncate(e[1] >> 8), .len = @truncate(e[1] >> 40) };
    }

    pub fn cell(t: Task, i: usize) *Cell {
        return switch (t.kind) {
            .list_whnf, .list_deep, .list_coerce => &t.obj.as(value.List).cells()[i],
            .attrs_whnf, .attrs_deep, .attrs_coerce, .prefetch => &t.obj.as(value.Attrs).attrs()[i].cell,
            .job => unreachable,
        };
    }
};

/// Fibers parked on thunks, by the address of the thunk's state cell.
const Shard = struct {
    lock: std.Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(usize, std.ArrayList(*Fiber)) = .empty,
};

/// `n` workers in all; the calling thread is worker 0, which runs the main fiber.
pub fn create(main: *Evaluator, n: usize) !*Pool {
    const gpa = main.gpa;
    const pool = try gpa.create(Pool);
    errdefer gpa.destroy(pool);
    pool.* = .{
        .gpa = gpa,
        .io = main.io,
        .main = main,
        .workers = try gpa.alloc(Worker, n),
        .lanes = try gpa.alloc(Lanes, n),
        .tune = .{ .spinner_cap = @max(n / 4, 1) },
        .fold = if (main.config.session) |s| s.settings.stats >= 1 else false,
    };
    for (pool.workers, pool.lanes, 0..) |*w, *l, k| {
        w.* = .{ .idx = k, .pool = pool, .interner = try main.interner.fork(), .local = if (k == 0) undefined else .init(gpa), .rng = 0x9E3779B97F4A7C15 ^ (k + 1) };
        l.* = .{ .ready = try .init(gpa, ready_cap), .tasks = try .init(gpa, task_cap) };
    }
    return pool;
}

pub fn destroy(pool: *Pool) void {
    const gpa = pool.gpa;
    for (pool.all.items) |f| {
        if (!f.is_main) f.own.deinitHelper();
        f.effects.deinit(gpa);
        unregisterGuard(@intFromPtr(f.stack.ptr));
        std.posix.munmap(f.stack);
        gpa.destroy(f);
    }
    for (pool.workers, pool.lanes, 0..) |*w, *l, k| {
        if (k > 0) w.local.deinit();
        w.interner.deinit();
        w.idle.deinit(gpa);
        l.ready.deinit(gpa);
        l.tasks.deinit(gpa);
    }
    for (&pool.waiters) |*s| {
        var it = s.map.valueIterator();
        while (it.next()) |list| list.deinit(gpa);
        s.map.deinit(gpa);
    }
    pool.overflow.deinit(gpa);
    pool.all.deinit(gpa);
    pool.fx.deinit(gpa);
    gpa.free(pool.workers);
    gpa.free(pool.lanes);
    gpa.destroy(pool);
}

/// Run `f(ev, ctx)` as the main fiber on this thread, with the other
/// workers beside it; return once it is done.
pub fn run(pool: *Pool, comptime f: anytype, ctx: anytype) !void {
    const Ctx = @TypeOf(ctx);
    const Wrap = struct {
        fn call(ev: *Evaluator, p: *anyopaque) void {
            f(ev, @as(Ctx, @ptrCast(@alignCast(p))));
        }
    };
    const m = try pool.newFiber(main_stack);
    m.is_main = true;
    m.id = 0;
    m.ev = pool.main;
    m.main_job = .{ .f = Wrap.call, .ctx = @ptrCast(ctx) };
    const saved = pool.main.local;
    // Fibers point the evaluator at their worker's fork, which `destroy`
    // frees; the caller keeps using the evaluator after the run.
    const saved_interner = pool.main.interner;
    defer pool.main.interner = saved_interner;
    pool.main.pool = pool;
    pool.workers[0].local = saved.*;
    var alt: [fault.alt_size]u8 align(16) = undefined;
    const old_alt = installOverflowHandler(&alt);
    defer fault.restoreAltStack(old_alt);
    for (pool.workers[1..]) |*w| w.thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, workerThread, .{ pool, w });
    const w0 = &pool.workers[0];
    const flat_arena = value.flat_arena;
    defer value.flat_arena = flat_arena;
    value.flat_arena = &w0.local.arena;
    pool.runFiber(w0, m);
    pool.drainLoop(w0);
    for (pool.workers[1..]) |*w| w.thread.?.join();
    saved.* = w0.local;
    pool.main.local = saved;
    pool.main.fiber = null;
    pool.main.pool = null;
}

fn newFiber(pool: *Pool, stack_size: usize) !*Fiber {
    const f = try pool.gpa.create(Fiber);
    errdefer pool.gpa.destroy(f);
    // Reserved, not committed: pages come as the stack grows. The lowest
    // page is the guard.
    const stack = std.posix.mmap(null, stack_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch
        return error.OutOfMemory;
    errdefer std.posix.munmap(stack);
    _ = std.os.linux.mprotect(stack.ptr, std.heap.page_size_min, .{});
    registerGuard(@intFromPtr(stack.ptr));
    f.* = .{ .stack = stack, .pool = pool, .id = pool.next_id.fetchAdd(1, .monotonic) };
    pool.all_lock.lockUncancelable(pool.io);
    defer pool.all_lock.unlock(pool.io);
    try pool.all.append(pool.gpa, f);
    errdefer _ = pool.all.pop();
    // A fiber is on the ready overflow at most once, so room for every
    // fiber makes `pushReady` unable to fail: a wake is never lost.
    {
        pool.overflow_lock.lockUncancelable(pool.io);
        defer pool.overflow_lock.unlock(pool.io);
        try pool.overflow.ensureTotalCapacity(pool.gpa, pool.all.items.len);
    }
    _ = pool.stats.fibers.fetchAdd(1, .monotonic);
    return f;
}

/// A fiber's first frame sits at the top of its stack; `entry` jumps to
/// `start` with it.
const Start = extern struct { fiber: *Fiber };

fn seed(f: *Fiber) void {
    const top = std.mem.alignBackward(usize, @intFromPtr(f.stack.ptr) + f.stack.len - @sizeOf(Start), 16);
    const s: *Start = @ptrFromInt(top);
    s.* = .{ .fiber = f };
    f.ctx = .{ .rsp = top - 8, .rbp = 0, .rip = @intFromPtr(&entry) };
}

fn entry() callconv(.naked) void {
    asm volatile (
        \\ leaq 8(%%rsp), %%rdi
        \\ jmp %[start:P]
        :
        : [start] "X" (&start),
    );
}

fn start(s: *Start, _: *const fiber_ctx.Switch) callconv(.withStackAlign(.c, 16)) noreturn {
    const f = s.fiber;
    const pool = f.pool;
    if (f.main_job) |m| {
        m.f(f.ev, m.ctx);
        pool.main_done.store(true, .release);
        pool.wakeAll();
    } else {
        f.ev.runTask(f.task);
    }
    f.state.store(.finished, .release);
    f.yield();
    unreachable;
}

// Stack overflow: the guard pages below fiber stacks and the fault
// handler's table of them.

/// Base addresses of the fiber stacks, for the fault handler. A fixed table
/// because the handler may not lock; more live fibers than this lose only
/// the message, not the exit code. A freed stack frees its entry.
const max_guards = 8192;
var guards: [max_guards]Atomic(usize) = @splat(.init(0));
var nguards: Atomic(usize) = .init(0);

fn registerGuard(base: usize) void {
    const n = @min(nguards.load(.acquire), max_guards);
    for (guards[0..n]) |*g| if (g.cmpxchgStrong(0, base, .acq_rel, .monotonic) == null) return;
    const i = nguards.fetchAdd(1, .acq_rel);
    if (i < max_guards) guards[i].store(base, .release);
}

fn unregisterGuard(base: usize) void {
    const n = @min(nguards.load(.acquire), max_guards);
    for (guards[0..n]) |*g| if (g.load(.acquire) == base) {
        g.store(0, .release);
        return;
    };
}

fn classify(addr: usize, _: []u8) ?fault.Fault {
    const n = @min(nguards.load(.acquire), max_guards);
    for (guards[0..n]) |*g| {
        const b = g.load(.acquire);
        if (b != 0 and addr >= b and addr < b + std.heap.page_size_min)
            return .{ .message = "error: stack overflow (possible infinite recursion)\n", .abort = false };
    }
    return null;
}

/// The guard-page handler on this thread, with `alt` as its alternate
/// stack (`sigaltstack` is per thread); returns the old one to restore.
fn installOverflowHandler(alt: []align(16) u8) std.os.linux.stack_t {
    const old = fault.altStack(alt);
    fault.install(classify);
    return old;
}

fn workerThread(pool: *Pool, w: *Worker) void {
    var alt: [fault.alt_size]u8 align(16) = undefined;
    const old = installOverflowHandler(&alt);
    defer fault.restoreAltStack(old);
    pool.drainLoop(w);
}

// Scheduling.

fn drainLoop(pool: *Pool, w: *Worker) void {
    value.flat_arena = &w.local.arena;
    var idle: u32 = 0;
    while (!pool.main_done.load(.acquire)) {
        if (pool.takeReady(w)) |f| {
            idle = 0;
            pool.foundWork(w);
            pool.runFiber(w, f);
            continue;
        }
        if (pool.takeTask(w)) |t| {
            idle = 0;
            pool.foundWork(w);
            pool.runTask(w, t);
            continue;
        }
        idle += 1;
        if (idle < pool.tune.spin and pool.maySpin(w)) {
            // Poll the two summary words until something appears.
            for (0..64) |_| {
                if (pool.hasWork()) break;
                std.atomic.spinLoopHint();
            }
            continue;
        }
        pool.stopSpinning(w);
        idle = 0;
        pool.sleep(w);
    }
}

fn runTask(pool: *Pool, w: *Worker, t: Task) void {
    const f = w.idle.pop() orelse blk: {
        const nf = pool.newFiber(helper_stack) catch return;
        nf.own = pool.main.forkHelper(&w.local, &w.interner, nf.id);
        nf.own.pool = pool;
        nf.own.fiber = nf;
        nf.ev = &nf.own;
        break :blk nf;
    };
    _ = pool.stats.tasks.fetchAdd(1, .monotonic);
    f.trimmed = false;
    f.task = t;
    f.cancel.store(false, .monotonic);
    f.own.par.cancelled = false;
    f.state.store(.new, .monotonic);
    pool.runFiber(w, f);
}

/// Resume `f` on `w`. The caller owns it: it is new, or this thread took
/// its single ready entry.
noinline fn runFiber(pool: *Pool, w: *Worker, f: *Fiber) void {
    if (f.state.load(.acquire) == .new) seed(f);
    f.state.store(.running, .monotonic);
    f.worker = w;
    f.ev.local = &w.local;
    f.ev.interner = &w.interner;
    f.ev.fiber = f;
    var sw: fiber_ctx.Switch = .{ .old = &w.ctx, .new = &f.ctx };
    _ = fiber_ctx.contextSwitch(&sw);
    switch (f.state.load(.acquire)) {
        .finished => if (!f.is_main) {
            if (pool.fold) pool.totals.add(&f.own.stats);
            // Without room the fiber is only not reused: `all` still frees it.
            w.idle.append(pool.gpa, f) catch {};
        },
        // A waker may already have moved `parking` to `woken`.
        .parking, .woken => if (f.state.swap(.suspended, .acq_rel) == .woken) pool.pushReady(w, f),
        else => |st| std.debug.panic("fiber switched out while {t}", .{st}),
    }
}

/// Make a parked fiber runnable. Any thread, any time: a spurious wake only
/// makes the fiber look at its wait again.
pub fn wake(pool: *Pool, w: *Worker, f: *Fiber) void {
    while (true) switch (f.state.load(.acquire)) {
        .suspended => if (f.state.cmpxchgWeak(.suspended, .runnable, .acq_rel, .acquire) == null) {
            pool.pushReady(w, f);
            return;
        },
        .parking => if (f.state.cmpxchgWeak(.parking, .woken, .acq_rel, .acquire) == null) return,
        else => return,
    };
}

fn pushReady(pool: *Pool, w: *Worker, f: *Fiber) void {
    _ = pool.pending_ready.fetchAdd(1, .seq_cst);
    if (!pool.lanes[w.idx].ready.push(.{ @intFromPtr(f), 0 })) {
        pool.overflow_lock.lockUncancelable(pool.io);
        pool.overflow.appendAssumeCapacity(f);
        pool.overflow_lock.unlock(pool.io);
        _ = pool.overflow_len.fetchAdd(1, .release);
    }
    pool.notify();
}

fn takeReady(pool: *Pool, w: *Worker) ?*Fiber {
    if (pool.pending_ready.load(.acquire) == 0) return null;
    const f = pool.scanReady(w) orelse return null;
    _ = pool.pending_ready.fetchSub(1, .seq_cst);
    return f;
}

fn scanReady(pool: *Pool, w: *Worker) ?*Fiber {
    if (pool.lanes[w.idx].ready.pop()) |e| return @ptrFromInt(e[0]);
    if (pool.overflow_len.load(.acquire) > 0) {
        pool.overflow_lock.lockUncancelable(pool.io);
        defer pool.overflow_lock.unlock(pool.io);
        if (pool.overflow.pop()) |f| {
            _ = pool.overflow_len.fetchSub(1, .release);
            return f;
        }
    }
    const n = pool.workers.len;
    const first = w.nextVictim();
    for (0..n) |k| {
        const v = (first + k) % n;
        if (v == w.idx) continue;
        if (pool.lanes[v].ready.steal()) |e| {
            _ = pool.stats.steals.fetchAdd(1, .monotonic);
            return @ptrFromInt(e[0]);
        }
    }
    return null;
}

/// Queue a task on the lane of the worker running the caller.
pub fn submit(pool: *Pool, w: *Worker, t: Task) bool {
    if (!pool.lanes[w.idx].tasks.push(t.pack())) return false;
    _ = pool.pending_tasks.fetchAdd(1, .seq_cst);
    pool.notify();
    return true;
}

fn takeTask(pool: *Pool, w: *Worker) ?Task {
    if (pool.main_done.load(.monotonic) or pool.pending_tasks.load(.acquire) == 0) return null;
    const t = pool.scanTasks(w) orelse return null;
    _ = pool.pending_tasks.fetchSub(1, .seq_cst);
    return t;
}

fn scanTasks(pool: *Pool, w: *Worker) ?Task {
    if (pool.lanes[w.idx].tasks.pop()) |e| return .unpack(e);
    const n = pool.workers.len;
    const first = w.nextVictim();
    for (0..n) |k| {
        const v = (first + k) % n;
        if (v == w.idx) continue;
        if (pool.lanes[v].tasks.steal()) |e| {
            _ = pool.stats.steals.fetchAdd(1, .monotonic);
            return .unpack(e);
        }
    }
    return null;
}

fn hasWork(pool: *Pool) bool {
    return pool.pending_ready.load(.acquire) > 0 or
        (!pool.main_done.load(.monotonic) and pool.pending_tasks.load(.acquire) > 0);
}

/// Register as a searcher. Worker 0, which carries the main fiber, is never
/// refused; the others only while fewer than the cap search.
fn maySpin(pool: *Pool, w: *Worker) bool {
    if (w.spinning) return true;
    if (w.idx != 0) {
        const cur = pool.spinners.load(.monotonic);
        if (cur >= pool.tune.spinner_cap or pool.spinners.cmpxchgStrong(cur, cur + 1, .seq_cst, .monotonic) != null) return false;
    } else _ = pool.spinners.fetchAdd(1, .seq_cst);
    w.spinning = true;
    return true;
}

fn stopSpinning(pool: *Pool, w: *Worker) void {
    if (!w.spinning) return;
    w.spinning = false;
    _ = pool.spinners.fetchSub(1, .seq_cst);
}

/// A searcher took work. The last searcher wakes one sleeper if work
/// remains, to keep one searcher alive.
fn foundWork(pool: *Pool, w: *Worker) void {
    if (!w.spinning) return;
    w.spinning = false;
    if (pool.spinners.fetchSub(1, .seq_cst) == 1 and pool.worthAWake() and pool.sleepers.load(.seq_cst) > 0) pool.wakeOne();
}

/// After publishing work: wake one sleeper only when no searcher is awake.
fn notify(pool: *Pool) void {
    seqCstFence();
    if (pool.sleepers.load(.monotonic) > 0 and pool.spinners.load(.monotonic) == 0 and pool.worthAWake()) pool.wakeOne();
}

/// A runnable fiber always is. Queued tasks are when the queue is deeper
/// than `handoff` per awake worker, or when only the caller is awake.
fn worthAWake(pool: *Pool) bool {
    if (pool.pending_ready.load(.acquire) > 0) return true;
    if (pool.main_done.load(.monotonic)) return false;
    const tasks = pool.pending_tasks.load(.acquire);
    if (tasks == 0) return false;
    const awake = pool.workers.len - pool.sleepers.load(.monotonic);
    return awake <= 1 or tasks > pool.tune.handoff * awake;
}

fn wakeOne(pool: *Pool) void {
    _ = pool.stats.wakes.fetchAdd(1, .monotonic);
    _ = pool.epoch.fetchAdd(1, .release);
    pool.io.futexWake(u32, &pool.epoch.raw, 1);
}

fn wakeAll(pool: *Pool) void {
    _ = pool.epoch.fetchAdd(1, .release);
    pool.io.futexWake(u32, &pool.epoch.raw, std.math.maxInt(u32));
}

fn sleep(pool: *Pool, w: *Worker) void {
    w.sleeps +%= 1;
    if (w.sleeps % 64 == 0) trimIdle(w);
    const asleep = pool.sleepers.fetchAdd(1, .seq_cst) + 1;
    defer _ = pool.sleepers.fetchSub(1, .seq_cst);
    const e = pool.epoch.load(.acquire);
    if (pool.main_done.load(.acquire) or pool.hasWork()) return;
    if (asleep == pool.workers.len) {
        // Everyone is asleep and main is not done: every fiber is parked
        // on another parked fiber. Break the cycle.
        pool.resolveDeadlock(w);
        return;
    }
    _ = pool.stats.sleeps.fetchAdd(1, .monotonic);
    pool.io.futexWaitUncancelable(u32, &pool.epoch.raw, e);
}

/// Idle fibers kept warm in full.
const trim_above = 16;
/// The top of a trimmed stack that stays resident.
const warm_stack = 64 << 10;

/// Give the stacks of idle fibers past the first few back to the kernel,
/// all but their warm top: a deep task leaves megabytes resident that the
/// next shallow one never touches.
fn trimIdle(w: *Worker) void {
    if (w.idle.items.len <= trim_above) return;
    for (w.idle.items[trim_above..]) |f| {
        if (f.trimmed) continue;
        std.posix.madvise(f.stack.ptr, f.stack.len - warm_stack, std.posix.MADV.DONTNEED) catch {};
        f.trimmed = true;
    }
}

/// Cancel every suspended helper: each unwinds, resetting the thunks it
/// holds, which wakes their waiters; the main fiber then meets the cycle
/// itself and reports what the sequential run reports.
fn resolveDeadlock(pool: *Pool, w: *Worker) void {
    _ = pool.stats.deadlocks.fetchAdd(1, .monotonic);
    pool.all_lock.lockUncancelable(pool.io);
    var woken: usize = 0;
    for (pool.all.items) |f| {
        if (f.is_main or f.state.load(.acquire) != .suspended) continue;
        f.cancel.store(true, .release);
        pool.wake(w, f);
        woken += 1;
    }
    pool.all_lock.unlock(pool.io);
    if (woken == 0 and !pool.hasWork()) @panic("iets: internal error: all workers idle with the main fiber parked");
}

/// A full fence; Zig has no `@fence`.
inline fn seqCstFence() void {
    var x: Atomic(u8) = .init(0);
    _ = x.fetchAdd(0, .seq_cst);
}

// The wait side of the claim protocol.

fn shardOf(pool: *Pool, key: usize) *Shard {
    return &pool.waiters[(key >> 4) % pool.waiters.len];
}

/// Park `f` until the state cell at `state` leaves the blackhole `cur`.
/// False when the fiber was cancelled while parked.
pub fn wait(pool: *Pool, f: *Fiber, state: *Atomic(u64), cur: Value) bool {
    const base = cur.bits() & ~Value.waiters_bit;
    for (0..wait_spin) |_| {
        if (state.load(.acquire) & ~Value.waiters_bit != base) return true;
        std.atomic.spinLoopHint();
    }
    const key = @intFromPtr(state);
    const s = pool.shardOf(key);
    {
        s.lock.lockUncancelable(pool.io);
        defer s.lock.unlock(pool.io);
        const now = state.load(.acquire);
        if (now & ~Value.waiters_bit != base) return true;
        // `parking` before the entry is visible, so a waker that finds the
        // entry sees `parking` or a later state.
        f.state.store(.parking, .release);
        if (state.cmpxchgStrong(now, now | Value.waiters_bit, .acq_rel, .acquire) != null) {
            f.state.store(.running, .release);
            return true;
        }
        const gop = s.map.getOrPut(pool.gpa, key) catch {
            f.state.store(.running, .release);
            return true;
        };
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // The main fiber goes first: it decides the result.
        const ok = if (f.is_main) gop.value_ptr.insert(pool.gpa, 0, f) else gop.value_ptr.append(pool.gpa, f);
        ok catch {
            f.state.store(.running, .release);
            return true;
        };
    }
    _ = pool.stats.parks.fetchAdd(1, .monotonic);
    const t0 = if (f.is_main) std.Io.Timestamp.now(pool.io, .awake) else undefined;
    f.yield();
    if (f.is_main) {
        _ = pool.stats.main_parks.fetchAdd(1, .monotonic);
        _ = pool.stats.main_wait_ns.fetchAdd(@intCast(t0.durationTo(std.Io.Timestamp.now(pool.io, .awake)).nanoseconds), .monotonic);
    }
    return !f.cancel.load(.acquire);
}

/// The thunk at `state` was published and had waiters: wake them all.
pub fn wakeWaiters(pool: *Pool, w: *Worker, state: *Atomic(u64)) void {
    const key = @intFromPtr(state);
    const s = pool.shardOf(key);
    s.lock.lockUncancelable(pool.io);
    var list = (s.map.fetchRemove(key) orelse {
        s.lock.unlock(pool.io);
        return;
    }).value;
    s.lock.unlock(pool.io);
    defer list.deinit(pool.gpa);
    for (list.items) |f| pool.wake(w, f);
}

pub fn noteFailed(pool: *Pool, key: usize) void {
    pool.any_failed.store(true, .monotonic);
    pool.failed[(key >> 4) % pool.failed.len].store(key, .monotonic);
}

/// True while `key` is one of the thunks that failed last.
pub fn isFailed(pool: *Pool, key: usize) bool {
    return pool.any_failed.load(.monotonic) and pool.failed[(key >> 4) % pool.failed.len].load(.monotonic) == key;
}
