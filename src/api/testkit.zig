//! Evaluation in this process, for the unit tests that would otherwise
//! spawn `iets eval`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const api = @import("../api.zig");
const Run = api.run.Run;
const EvalArgs = api.EvalArgs;
const Session = @import("../session.zig").Session;
const env_ = @import("../env.zig");
const print = @import("../eval/print.zig");

/// What `iets eval` would have printed: stdout, the exit code and stderr.
pub const Outcome = struct {
    out: []u8,
    rc: u8,
    err: []u8,

    pub fn deinit(o: Outcome, gpa: Allocator) void {
        gpa.free(o.out);
        gpa.free(o.err);
    }
};

/// One evaluation as `iets eval` does it, in a session of its own with an
/// isolated environment: no nix.conf, no `iets.toml`. `--strict` forces
/// deeply; the value is printed in Nix's `--eval` form.
pub fn eval(gpa: Allocator, io: std.Io, a: *const EvalArgs) !Outcome {
    var map = try env_.isolated(gpa);
    defer map.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const init: std.process.Init = .{
        .minimal = undefined,
        .arena = &arena,
        .gpa = gpa,
        .io = io,
        .environ_map = &map,
        .preopens = undefined,
    };
    const s = try Session.create(gpa, io, .process(&map));
    defer s.destroy();
    // the log writes under its own lock, so workers need none here
    var log: std.Io.Writer.Allocating = .init(gpa);
    defer log.deinit();
    s.log.writeTo(&log.writer);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const run: Run = .{ .s = s, .init = &init, .args = a, .keep_aterm = true, .keep_site = a.dump_drvs == null };
    const Ctx = struct { a: *const EvalArgs, out: *std.Io.Writer, arena: Allocator };
    const rc = run.go(Ctx{ .a = a, .out = &out.writer, .arena = arena.allocator() }, struct {
        fn go(c: Ctx, ev: *Evaluator) !u8 {
            const v = try api.evaluate(ev, c.arena, c.a, ev.config.cwd);
            const forced = if (c.a.strict) try ev.forceDeep(v) else try ev.force(v);
            print.writeAmbiguous(ev, c.out, forced) catch |e| return switch (e) {
                error.WriteFailed => error.OutOfMemory,
                else => e,
            };
            return 0;
        }
    }.go);
    const o = try out.toOwnedSlice();
    errdefer gpa.free(o);
    return .{ .out = o, .rc = rc, .err = try log.toOwnedSlice() };
}

test "an evaluation prints its value, an error its report" {
    const gpa = std.testing.allocator;
    var ok = try eval(gpa, std.testing.io, &.{ .input = .{ .expr = "{ a = 1 + 1; b = [ \"x\" ]; }" }, .strict = true, .no_ir_cache = true, .workers = 1 });
    defer ok.deinit(gpa);
    try std.testing.expectEqualStrings("{ a = 2; b = [ \"x\" ]; }", ok.out);
    try std.testing.expectEqual(@as(u8, 0), ok.rc);
    try std.testing.expectEqualStrings("", ok.err);

    var bad = try eval(gpa, std.testing.io, &.{ .input = .{ .expr = "builtins.trace \"t\" (throw \"boom\")" }, .no_ir_cache = true, .workers = 1 });
    defer bad.deinit(gpa);
    try std.testing.expectEqualStrings("", bad.out);
    try std.testing.expectEqual(@as(u8, 1), bad.rc);
    try std.testing.expect(std.mem.startsWith(u8, bad.err, "trace: t\nerror: boom\n"));
}

test "an --arg is evaluated only when the function uses it" {
    const gpa = std.testing.allocator;
    var o = try eval(gpa, std.testing.io, &.{
        .input = .{ .expr = "{ x, y ? 0 }: x + 1" },
        .args = &.{ .{ .name = "x", .text = "41", .is_str = false }, .{ .name = "z", .text = "throw \"unused\"", .is_str = false } },
        .no_ir_cache = true,
        .workers = 1,
    });
    defer o.deinit(gpa);
    try std.testing.expectEqualStrings("42", o.out);
}
