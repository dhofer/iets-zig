//! `iets prefetch`: the hash of what a URL serves, or of what a fixed-output
//! derivation produces, on stdout (docs/reference/commands.md); and the
//! work of the classic `nix flake prefetch-inputs` (cli/classic/nix.zig
//! checks its command line).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Session = @import("../session.zig").Session;
const log = @import("../log.zig");
const Report = log.Report;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const http = @import("../fetch/http.zig");
const spool = @import("../fetch/spool.zig");
const cli = @import("../cli.zig");
const plumbing = @import("plumbing.zig");
const Args = @import("args.zig").Args;
const api_flake = @import("../api/flake.zig");
const source = @import("../source.zig");
const remote = source.remote;
const treestore = @import("../treestore.zig");
const cachefs = @import("../cachefs.zig");
const Evaluator = @import("../eval/Evaluator.zig");

/// `iets prefetch ARGS`: `plumbing fetch` with `--json` a choice.
pub fn cmd(c: *const cli.Ctx, argv: []const []const u8) u8 {
    const s = c.s;
    s.log.command = "prefetch";
    var a: Args = .{ .s = s, .arena = c.init.arena.allocator(), .cmd = "prefetch", .argv = argv };
    for (argv) |x| if (std.mem.eql(u8, x, "--help") or std.mem.eql(u8, x, "-h")) return a.report(error.Help);
    var json = false;
    var rest: std.ArrayList([]const u8) = .empty;
    for (argv) |x| {
        if (std.mem.eql(u8, x, "--json")) {
            json = true;
        } else rest.append(a.arena, x) catch return a.report(error.OutOfMemory);
    }
    const f = plumbing.fetchFlags(&a, rest.items) catch |e| return a.report(e);
    return plumbing.fetch(c, &a, f, json) catch |e| a.report(e);
}

/// The download limits of a run: the nix.conf timeouts (0 is no limit) and
/// the `fetch-max-size` setting.
pub fn limits(s: *const Session) http.Limits {
    var l: http.Limits = .{ .max_size = s.settings.fetch_max_size };
    if (s.nix_conf) |*conf| {
        var d: Diag = .init(s.gpa);
        defer d.deinit();
        if (conf.int("connect-timeout", &d) catch null) |n| l.connect_ns = if (n > 0) n * std.time.ns_per_s else null;
        if (conf.int("stalled-download-timeout", &d) catch null) |n| l.stall_ns = if (n > 0) n * std.time.ns_per_s else null;
    }
    return l;
}

/// What `nix flake prefetch-inputs` resolves in one thread: its own
/// evaluator over the shared tables, one per input.
const Worker = struct {
    s: *Session,
    shared: *Evaluator.Shared,
    inputs: *treestore.Store,
    system: []const u8,
    queue: *Queue,
    failed: *std.atomic.Value(bool),

    const Queue = struct {
        lock: Io.Mutex = .init,
        items: []const api_flake.Input,
        next: usize = 0,

        fn pop(q: *Queue, io: Io) ?api_flake.Input {
            q.lock.lockUncancelable(io);
            defer q.lock.unlock(io);
            if (q.next >= q.items.len) return null;
            defer q.next += 1;
            return q.items[q.next];
        }
    };

    fn run(w: *Worker) void {
        const gpa = w.s.gpa;
        const io = w.s.io;
        while (w.queue.pop(io)) |in| {
            var interner = @import("../syntax/symbol.zig").Interner.init(gpa) catch return w.failed.store(true, .monotonic);
            defer interner.deinit();
            var files: @import("../eval/Files.zig") = .init(gpa, io);
            defer files.deinit();
            var local: Evaluator.Local = .init(gpa);
            defer local.deinit();
            var ev = Evaluator.init(gpa, io, &local, &interner, &files, w.shared, .{
                .pure = true,
                .system = w.system,
                .session = w.s,
                .inputs = w.inputs,
                .fetch_limits = limits(w.s),
                .offline = w.s.settings.offline,
            }) catch return w.failed.store(true, .monotonic);
            defer ev.deinit();
            if (in.source.narHash()) |h| remote.nameInput(&ev, h, in.name) catch {};
            _ = source.tree(&ev, &in.source, .none) catch {
                const f = ev.failure orelse continue;
                var msg = f.msg;
                if (std.mem.startsWith(u8, msg, "iets: ")) msg = msg["iets: ".len..];
                const r: Report = .{ .code = f.kind.code(), .raw = msg, .hint = f.hint };
                _ = r.emit(&w.s.log);
                w.failed.store(true, .monotonic);
            };
        }
    }
};

/// The default of `http-connections`, the threads Nix fetches on.
const http_connections = 25;

/// flake-prefetch-inputs.cc: every locked input of `todo`, resolved in
/// parallel the way an evaluation resolves it (`source.tree`), on as many
/// threads as `http-connections`' default. The exit code: 1 when one failed.
pub fn fetchInputs(s: *Session, arena: Allocator, todo: []const api_flake.Input) !u8 {
    const system = if (s.nix_conf) |*c| c.system() else "x86_64-linux";
    var shared: Evaluator.Shared = .{};
    defer shared.deinit(s.gpa);
    const root = try treestore.locate(arena, try cachefs.root(arena, s.env.map orelse return 1, s.settings.cache_dir));
    var store: treestore.Store = .init(s.gpa, s.io, root);
    defer store.deinit();
    var queue: Worker.Queue = .{ .items = todo };
    var failed: std.atomic.Value(bool) = .init(false);
    var w: Worker = .{ .s = s, .shared = &shared, .inputs = &store, .system = system, .queue = &queue, .failed = &failed };
    const n = @min(todo.len, http_connections);
    const threads = try arena.alloc(std.Thread, n);
    var started: usize = 0;
    for (threads) |*t| {
        t.* = std.Thread.spawn(.{ .stack_size = 64 << 20 }, Worker.run, .{&w}) catch break;
        started += 1;
    }
    for (threads[0..started]) |t| t.join();
    return @intFromBool(failed.load(.monotonic));
}
