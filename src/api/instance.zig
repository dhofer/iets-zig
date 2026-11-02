//! An evaluator with the tables it owns, for a host to embed. `api.run.Run` sets one up from an
//! `EvalArgs` the way the commands do; this is for a host that brings its own
//! `Evaluator.Config` (docs/reference/library.md, "Entry points").

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const Files = @import("../eval/Files.zig");
const Interner = @import("../syntax/symbol.zig").Interner;
const builtins = @import("../builtins.zig");
const value = @import("../runtime/value.zig");
const LogWriter = @import("run.zig").LogWriter;

pub const Instance = struct {
    gpa: Allocator,
    interner: Interner,
    files: Files,
    shared: Evaluator.Shared = .{},
    local: Evaluator.Local,
    ev: Evaluator,
    /// The lint warnings and the evaluator's own lines go to the session's
    /// log, when the config names a session.
    log: LogWriter = undefined,

    /// An evaluator with the builtins installed. Two defaults differ from
    /// the command line: evaluation is impure unless
    /// `config.pure`, and there is no project root unless
    /// `config.project_root`. Use it from the thread that made it, or set
    /// `runtime.value.flat_arena` on the thread that does.
    pub fn create(gpa: Allocator, io: std.Io, config: Evaluator.Config) !*Instance {
        const i = try gpa.create(Instance);
        errdefer gpa.destroy(i);
        i.gpa = gpa;
        i.interner = try .init(gpa);
        errdefer i.interner.deinit();
        i.files = .init(gpa, io);
        errdefer i.files.deinit();
        i.shared = .{};
        errdefer i.shared.deinit(gpa);
        i.local = .init(gpa);
        errdefer i.local.deinit();
        i.ev = try .init(gpa, io, &i.local, &i.interner, &i.files, &i.shared, config);
        errdefer i.ev.deinit();
        if (config.session) |s| {
            i.log = .{ .log = &s.log };
            i.ev.stderr = &i.log.interface;
            i.shared.lints.out = &i.log.interface;
        }
        // a `//` result flattens into the running thread's arena
        if (value.flat_arena == null) value.flat_arena = &i.local.arena;
        errdefer if (value.flat_arena == &i.local.arena) {
            value.flat_arena = null;
        };
        try builtins.install(&i.ev);
        return i;
    }

    /// Frees every value the evaluator made; the lint warnings not yet
    /// written are written first.
    pub fn destroy(i: *Instance) void {
        @import("../lint.zig").report.flush(&i.ev);
        if (value.flat_arena == &i.local.arena) value.flat_arena = null;
        i.ev.deinit();
        i.local.deinit();
        i.shared.deinit(i.gpa);
        i.files.deinit();
        i.interner.deinit();
        i.gpa.destroy(i);
    }

    /// `f(ctx, ev)` as the main fiber of `workers` evaluator threads, the
    /// calling one included; with one worker a plain call. The main fiber has `api.main_stack`; with one
    /// worker `f` runs on the caller's stack.
    pub fn run(i: *Instance, workers: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Evaluator) void) !void {
        const C = @TypeOf(ctx);
        const Job = struct {
            ctx: C,
            fn go(e: *Evaluator, j: *@This()) void {
                f(j.ctx, e);
            }
        };
        var job: Job = .{ .ctx = ctx };
        if (workers <= 1) return Job.go(&i.ev, &job);
        // helpers copy the globals, so they start once those are complete
        i.ev.par.on = true;
        defer i.ev.par.on = false;
        const pool = try Evaluator.Pool.create(&i.ev, workers);
        defer pool.destroy();
        try pool.run(Job.go, &job);
    }
};

test "an instance evaluates, and on worker threads" {
    const inst = try Instance.create(std.testing.allocator, std.testing.io, .{});
    defer inst.destroy();
    const import_ = @import("../eval/import.zig");
    const v = try inst.ev.forceDeep(try import_.evalString(&inst.ev, "builtins.foldl' (a: b: a + b) 0 (builtins.genList (x: x) 1000)"));
    try std.testing.expectEqual(@as(i64, 499500), v.view().int);

    const Out = struct { got: i64 = 0 };
    var out: Out = .{};
    try inst.run(4, &out, struct {
        fn go(o: *Out, ev: *Evaluator) void {
            const r = import_.evalString(ev, "builtins.length (builtins.genList (i: { a = i; }) 5000)") catch return;
            const w = ev.forceDeep(r) catch return;
            o.got = w.view().int;
        }
    }.go);
    try std.testing.expectEqual(@as(i64, 5000), out.got);
}
