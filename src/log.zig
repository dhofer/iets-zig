//! Everything a command says on stderr goes through here: Nix's plain text,
//! or with `--log-format internal-json` one `@nix {...}` line per message in
//! the format of logging.cc:JSONLogger, plus `code` and `hint` on an error
//! (docs/reference/errors.md). The `json-log-path` file gets every record in
//! either format.
//!
//! The state is a `Log`, which a `Session` owns. Every function takes the
//! `*Log` rather than finding it through the thread: fibers migrate.

const std = @import("std");
const writeString = @import("syntax/text.zig").writeJsonString;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const sys = @import("sys.zig");
const Env = @import("env.zig").Env;
const display = @import("display.zig");
const Display = display.Display;
const Term = display.Term;
const progress = @import("progress.zig");
const config = @import("config.zig");
const errors = @import("errors.zig");
const bytes_ = @import("bytes.zig");

/// error.hh:Verbosity, and logging.hh:ActivityType and ResultType, the ones
/// iets emits itself.
pub const lvl_error: u64 = 0;
pub const lvl_info: u64 = 3;
pub const lvl_talkative: u64 = 4;
pub const act_unknown: u64 = 0;
pub const act_copy_path: u64 = 100;
pub const act_file_transfer: u64 = 101;
pub const act_realise: u64 = 102;
pub const act_copy_paths: u64 = 103;
pub const act_builds: u64 = 104;
pub const act_build: u64 = 105;
pub const act_substitute: u64 = 108;
pub const act_query_path_info: u64 = 109;
pub const act_fetch_tree: u64 = 112;
pub const res_build_log_line: u64 = 101;
pub const res_set_phase: u64 = 104;
pub const res_progress: u64 = 105;

/// One element of an activity's `fields`.
pub const Field = union(enum) {
    str: []const u8,
    int: i64,
};

/// What every fixed-output hash mismatch message starts with.
pub const mismatch_text = "hash mismatch in fixed-output derivation";

pub const Pair = struct { specified: []u8, got: []u8 };

/// What a command's flags and the session say about the text it writes.
const Out = struct {
    w: ?*std.Io.Writer = null,
    /// The terminal the live view is drawn on.
    term: Term = .stderr,
    status: std.ArrayList(u8) = .empty,
    /// Lines under the output, redrawn in place: the build renderer's view.
    region: std.ArrayList([]u8) = .empty,
    /// Drawn while a terminal answers and nothing has paused it.
    display: ?Display = null,
    /// A child may prompt on the terminal while this is above zero.
    paused: usize = 0,
    /// What was written without its newline, until it has one.
    partial: std.ArrayList(u8) = .empty,

    fn deinit(o: *Out, gpa: Allocator) void {
        o.status.deinit(gpa);
        freeLines(gpa, &o.region);
        if (o.display) |*d| d.deinit(gpa);
        o.partial.deinit(gpa);
    }

    /// Output goes through the display while there is one.
    fn write(o: *Out, gpa: Allocator, b: []const u8) void {
        if (o.display == null) {
            o.send(b);
            o.sync(gpa);
            return;
        }
        o.partial.appendSlice(gpa, b) catch return;
        const end = std.mem.lastIndexOfScalar(u8, o.partial.items, '\n') orelse return;
        const done = gpa.dupe(u8, o.partial.items[0..end]) catch return;
        defer gpa.free(done);
        o.partial.replaceRangeAssumeCapacity(0, end + 1, &.{});
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(gpa);
        var it = std.mem.splitScalar(u8, done, '\n');
        while (it.next()) |l| lines.append(gpa, std.mem.trimEnd(u8, l, "\r")) catch return;
        o.paint(gpa, lines.items);
    }

    fn send(o: *Out, b: []const u8) void {
        const w = o.w orelse return;
        w.writeAll(b) catch {};
        w.flush() catch {};
    }

    /// The lines under the output: the region, then the status line.
    fn live(o: *const Out, buf: *std.ArrayList([]const u8), gpa: Allocator) void {
        for (o.region.items) |l| buf.append(gpa, l) catch return;
        if (o.status.items.len > 0) buf.append(gpa, o.status.items) catch return;
    }

    fn liveEmpty(o: *const Out) bool {
        return o.region.items.len == 0 and o.status.items.len == 0;
    }

    /// Brings the display in line with what is to be shown: starts it, ends
    /// it or redraws it. A new size redraws it too.
    fn sync(o: *Out, gpa: Allocator) void {
        const wanted = o.paused == 0 and !o.liveEmpty() and o.w != null;
        const size = if (wanted) o.term.size() else null;
        if (size) |sz| {
            if (o.display == null) {
                const rows = sz[1];
                const at = o.term.cursor() orelse [2]usize{ rows, 1 };
                // a line somebody has not ended must not be drawn over
                const origin = if (at[1] == 1) at[0] else blk: {
                    o.send("\n");
                    break :blk @min(at[0] + 1, rows);
                };
                o.display = .init(origin);
            }
            o.paint(gpa, &.{});
        } else if (o.display != null) o.close(gpa);
    }

    fn paint(o: *Out, gpa: Allocator, output: []const []const u8) void {
        const size = o.term.size() orelse return o.close(gpa);
        const d = &(o.display orelse return o.close(gpa));
        var live_lines: std.ArrayList([]const u8) = .empty;
        defer live_lines.deinit(gpa);
        o.live(&live_lines, gpa);
        const frame = d.frame(gpa, size, output, live_lines.items) catch return;
        defer gpa.free(frame);
        o.send(frame);
        o.term.guard(d.top);
    }

    fn close(o: *Out, gpa: Allocator) void {
        var d = o.display orelse return;
        o.display = null;
        var buf: [64]u8 = undefined;
        o.send(d.close(&buf));
        d.deinit(gpa);
        o.send(o.partial.items);
        o.partial.clearRetainingCapacity();
        o.term.guard(0);
    }
};

fn freeLines(gpa: Allocator, l: *std.ArrayList([]u8)) void {
    for (l.items) |x| gpa.free(x);
    l.deinit(gpa);
}

/// Where one session's messages go and what it saw on the way.
pub const Log = struct {
    gpa: Allocator,
    io: std.Io,
    /// For `IETS_SESSION_ID`, `TERM`, `NO_COLOR` and the nix.conf files.
    env: Env = .{},
    json: std.atomic.Value(bool) = .init(false),
    show_trace: std.atomic.Value(bool) = .init(false),
    /// Under one of Nix's names stderr holds what Nix prints and nothing else.
    classic: std.atomic.Value(bool) = .init(false),
    /// The command whose help applies; null is classic mode, whose errors
    /// all exit 1. `cli/run.zig` sets it once it knows the command; a
    /// library session reports as `eval`.
    command: ?[]const u8 = "eval",
    json_log_path: ?[]u8 = null,
    /// The `json-log-path` writer, opened on first use.
    sink_state: enum { unset, none, open } = .unset,
    sink: sys.fs.FdWriter = .{ .fd = -1 },
    sink_lock: std.Io.Mutex = .init,
    sid: [36]u8 = undefined,
    sid_len: usize = 0,
    next_activity: std.atomic.Value(u64) = .init(0),
    /// Guards the mismatch lists and `want_mismatch`.
    mismatch_lock: std.Io.Mutex = .init,
    mismatches: std.ArrayList(Pair) = .empty,
    /// Mismatches a build reported, before `resolveMismatches` says which of
    /// them are about a fixed-output derivation the client planned.
    pending: std.ArrayList(Pair) = .empty,
    want_mismatch: ?[]u8 = null,
    /// Where messages go. No writer writes nowhere: a library says nothing
    /// unless the host asked for it. `iets` points it at stderr.
    err_lock: std.Io.Mutex = .init,
    out: Out = .{},
    progress: progress.Board,
    /// Whether stderr is a terminal, read once (`filter_ansi` keeps colours
    /// only for one). Tests set it.
    stderr_tty: ?bool = null,
    /// A line on its way to the display, under `err_lock`.
    scratch: std.Io.Writer.Allocating,
    /// A record on its way to the sink, under `sink_lock`: one write each.
    sink_buf: std.Io.Writer.Allocating,

    pub fn init(gpa: Allocator, io: std.Io, env: Env) Log {
        return .{
            .gpa = gpa,
            .io = io,
            .env = env,
            .progress = .init(gpa, io),
            .scratch = .init(gpa),
            .sink_buf = .init(gpa),
        };
    }

    /// After `init`, once the log has its final address: the progress
    /// ticker draws on it.
    pub fn attach(l: *Log) void {
        l.progress.owner = l;
    }

    pub fn deinit(l: *Log) void {
        l.out.deinit(l.gpa);
        l.scratch.deinit();
        l.sink_buf.deinit();
        l.progress.deinit();
        if (l.json_log_path) |p| l.gpa.free(p);
        if (l.sink_state == .open) l.sink.close();
        for ([_]*std.ArrayList(Pair){ &l.mismatches, &l.pending }) |v| {
            for (v.items) |p| freePair(l.gpa, p);
            v.deinit(l.gpa);
        }
        if (l.want_mismatch) |w| l.gpa.free(w);
    }

    /// Sends every message to `w`.
    pub fn writeTo(l: *Log, w: *std.Io.Writer) void {
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        l.out.w = w;
    }

    /// The terminal the live view is drawn on, for a test.
    pub fn setTerm(l: *Log, t: Term) void {
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        l.out.term = t;
    }

    /// The status line under the output; empty takes it down.
    pub fn setStatus(l: *Log, line: []const u8) !void {
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        if (std.mem.eql(u8, l.out.status.items, line)) return;
        l.out.status.clearRetainingCapacity();
        try l.out.status.appendSlice(l.gpa, line);
        l.out.sync(l.gpa);
    }

    /// The lines above the status line that are redrawn in place. Empty
    /// takes them down.
    pub fn setRegion(l: *Log, lines: []const []const u8) !void {
        var copy: std.ArrayList([]u8) = .empty;
        errdefer freeLines(l.gpa, &copy);
        for (lines) |x| try copy.append(l.gpa, try l.gpa.dupe(u8, x));
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        freeLines(l.gpa, &l.out.region);
        l.out.region = copy;
        l.out.sync(l.gpa);
    }

    /// Takes the live view down while a child may prompt on the terminal.
    pub fn pause(l: *Log, on: bool) void {
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        l.out.paused = if (on) l.out.paused + 1 else l.out.paused -| 1;
        l.out.sync(l.gpa);
    }

    /// `bytes` as they are, for output a caller already formatted.
    pub fn err(l: *Log, b: []const u8) void {
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        l.out.write(l.gpa, b);
    }

    /// One line, in one write.
    pub fn errln(l: *Log, text: []const u8) void {
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        const w = &l.scratch.writer;
        l.scratch.clearRetainingCapacity();
        w.writeAll(text) catch return;
        w.writeByte('\n') catch return;
        l.out.write(l.gpa, l.scratch.written());
    }

    /// `--log-format F`, loggers.cc:parseLogFormat. Every format but
    /// `internal-json` is plain text here. The error text goes to `d`.
    pub fn setFormat(l: *Log, f: []const u8, d: *@import("diag.zig").Diag) errors.Error!void {
        if (std.mem.eql(u8, f, "raw") or std.mem.eql(u8, f, "raw-with-logs")) {
            l.json.store(false, .monotonic);
            l.progress.setMode(.lines);
        } else if (std.mem.eql(u8, f, "bar") or std.mem.eql(u8, f, "bar-with-logs")) {
            l.json.store(false, .monotonic);
            l.progress.setMode(.bar);
        } else if (std.mem.eql(u8, f, "internal-json")) {
            l.json.store(true, .monotonic);
        } else return d.fail(error.Usage, "option 'log-format' has an invalid value '{s}'", .{f});
    }

    pub fn isJson(l: *const Log) bool {
        return l.json.load(.monotonic);
    }

    /// `--show-trace`: the text always has the trace; a record carries it
    /// only then, as in Nix.
    pub fn setShowTrace(l: *Log) void {
        l.show_trace.store(true, .monotonic);
    }

    /// This process answers to one of Nix's names.
    pub fn setClassic(l: *Log) void {
        l.classic.store(true, .monotonic);
    }

    pub fn isClassic(l: *const Log) bool {
        return l.classic.load(.monotonic);
    }

    /// `json-log-path` from the command line; it wins over nix.conf. Set it
    /// before the first line goes out.
    pub fn setJsonLogPath(l: *Log, path: []const u8) !void {
        if (l.json_log_path != null) return;
        l.json_log_path = try l.gpa.dupe(u8, path);
    }

    /// `sid`, the session of every record: `IETS_SESSION_ID` when a parent
    /// iets or the user set it, else a UUIDv7 made for this one.
    pub fn sessionId(l: *Log) []const u8 {
        l.sink_lock.lockUncancelable(l.io);
        defer l.sink_lock.unlock(l.io);
        return l.sidLocked();
    }

    fn sidLocked(l: *Log) []const u8 {
        if (l.sid_len == 0) {
            if (l.env.nonEmpty("IETS_SESSION_ID")) |s| {
                const n = @min(s.len, l.sid.len);
                @memcpy(l.sid[0..n], s[0..n]);
                l.sid_len = n;
            } else {
                var r: [10]u8 = undefined;
                sys.random(&r);
                l.sid = uuidV7(sys.unixMillis(), r);
                l.sid_len = 36;
            }
        }
        return l.sid[0..l.sid_len];
    }

    /// Whether stderr is a terminal.
    fn stderrIsTty(l: *Log) bool {
        if (l.stderr_tty == null) l.stderr_tty = sys.tty.isTerminal(2);
        return l.stderr_tty.?;
    }

    /// A terminal that takes cursor movement. `TERM=dumb` is one that does not.
    pub fn interactive(l: *Log) bool {
        const term = l.env.get("TERM") orelse return false;
        return l.stderrIsTty() and !std.mem.eql(u8, term, "dumb");
    }

    /// Whether the status line gets colours.
    pub fn color(l: *Log) bool {
        return l.interactive() and l.env.get("NO_COLOR") == null and !l.isJson();
    }

    /// logging.cc:applyJSONLogger: a copy of the record, without the
    /// `@nix ` prefix, to the `json-log-path` file or unix socket, in one
    /// write. A path that does not open is reported once and ignored, as
    /// Nix does.
    fn tee(l: *Log, rec: Record) void {
        if (!l.sinkOpen()) return;
        l.sink_lock.lockUncancelable(l.io);
        defer l.sink_lock.unlock(l.io);
        const b = &l.sink_buf;
        b.clearRetainingCapacity();
        rec.write(&b.writer, l.sidLocked()) catch return;
        b.writer.writeByte('\n') catch return;
        sys.fs.writeAll(l.sink.fd, b.written()) catch {};
    }

    /// Opens the sink on first use: `--json-log-path`, else nix.conf's.
    fn sinkOpen(l: *Log) bool {
        l.sink_lock.lockUncancelable(l.io);
        if (l.sink_state != .unset) {
            defer l.sink_lock.unlock(l.io);
            return l.sink_state == .open;
        }
        l.sink_state = .none;
        l.sink_lock.unlock(l.io);
        var from_conf: ?config.Config = null;
        defer if (from_conf) |*c| c.deinit();
        // `Config.read`, not `load`: a warning would come back here
        const path = l.json_log_path orelse blk: {
            var d: @import("diag.zig").Diag = .init(l.gpa);
            defer d.deinit();
            from_conf = config.Config.read(l.gpa, l.io, l.env, &.{}, &d) catch return false;
            break :blk from_conf.?.str("json-log-path") orelse return false;
        };
        switch (sys.fs.openSink(path)) {
            .fd => |fd| {
                l.sink_lock.lockUncancelable(l.io);
                defer l.sink_lock.unlock(l.io);
                l.sink = .{ .fd = fd };
                l.sink_state = .open;
                return true;
            },
            .err => |e| {
                var buf: [std.fs.max_path_bytes + 128]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "error (ignored): opening log file \"{s}\": {s}", .{ path, errors.errnoText(e) }) catch return false;
                l.errln(line);
                return false;
            },
        }
    }

    /// One record: `rec` under internal-json, else `text` if any.
    fn emit(l: *Log, rec: Record, text: ?[]const u8) void {
        if (l.isJson() or text != null) l.show(rec, text orelse "");
        l.tee(rec);
    }

    /// One line on stderr. It is put together in `scratch` first: stderr
    /// is unbuffered, and a write per fragment would be a system call each.
    fn show(l: *Log, rec: Record, text: []const u8) void {
        const sid = if (l.isJson()) l.sessionId() else "";
        l.err_lock.lockUncancelable(l.io);
        defer l.err_lock.unlock(l.io);
        l.scratch.clearRetainingCapacity();
        l.writeShown(&l.scratch.writer, rec, text, sid) catch return;
        l.out.write(l.gpa, l.scratch.written());
    }

    /// The line as stderr shows it: the record under internal-json, else
    /// `text` as logging.cc:SimpleLogger::log filters it.
    fn writeShown(l: *Log, w: *std.Io.Writer, rec: Record, text: []const u8, sid: []const u8) !void {
        if (l.isJson()) {
            try w.writeAll("@nix ");
            try rec.write(w, sid);
        } else try filterAnsiInto(w, text, !l.stderrIsTty());
        try w.writeByte('\n');
    }

    // Activities.

    /// Whether activity records go anywhere, so nobody builds one for nothing.
    pub fn activities(l: *Log) bool {
        return l.records() or l.drawn();
    }

    fn records(l: *Log) bool {
        return l.isJson() or l.sinkOpen();
    }

    /// Not under internal-json: its records carry the progress.
    fn drawn(l: *Log) bool {
        return l.progress.mode() != .off and !l.isJson();
    }

    /// loggers.cc:makeDefaultLogger, unless `--log-format` chose.
    pub fn showProgress(l: *Log) void {
        if (l.progress.mode() != .off) return;
        l.progress.setMode(if (l.interactive()) .bar else .lines);
    }

    /// logging.cc:Activity: the pid in the high half, a counter below.
    pub fn activityId(l: *Log) u64 {
        return l.next_activity.fetchAdd(1, .monotonic) + (@as(u64, sys.pid()) << 32);
    }

    /// logging.cc:JSONLogger::startActivity.
    pub fn start(l: *Log, id: u64, level: u64, ty: u64, text: []const u8, f: []const Field, parent: u64) void {
        if (l.drawn()) {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(l.gpa);
            if (l.progress.start(id, level, ty, text, parent, l.isClassic(), &line) catch false) l.errln(line.items);
        }
        if (l.records()) l.emit(.{ .start = .{ .id = id, .level = level, .ty = ty, .text = text, .fields = f, .parent = parent } }, null);
    }

    /// logging.cc:JSONLogger::stopActivity.
    pub fn stop(l: *Log, id: u64) void {
        if (l.drawn() and l.progress.stop(id)) l.setStatus("") catch {};
        if (l.records()) l.emit(.{ .stop = id }, null);
    }

    /// logging.cc:JSONLogger::result.
    pub fn result(l: *Log, id: u64, ty: u64, f: []const Field) void {
        if (l.drawn()) l.progress.result(id, ty, f);
        if (l.records()) l.emit(.{ .result = .{ .id = id, .ty = ty, .fields = f } }, null);
    }

    /// Status line only: Nix has no record for it.
    pub fn detail(l: *Log, id: u64, text: []const u8) void {
        if (l.drawn()) l.progress.detail(id, text) catch {};
    }

    /// No status line until `unsuspend`: a child may prompt on the terminal.
    pub fn @"suspend"(l: *Log) void {
        l.progress.@"suspend"();
        l.pause(true);
    }

    pub fn unsuspend(l: *Log) void {
        l.progress.@"resume"();
        l.pause(false);
    }

    /// An activity of iets's own; `end` stops it.
    pub fn activity(l: *Log, parent: u64, level: u64, ty: u64, text: []const u8, f: []const Field) Activity {
        const id = l.activityId();
        l.start(id, level, ty, text, f, parent);
        return .{ .log = l, .id = id };
    }

    // Messages.

    /// logging.cc:JSONLogger::log: `text` at `level`, whatever its prefix.
    pub fn msg(l: *Log, level: u8, text: []const u8) void {
        l.emit(.{ .msg = .{ .level = level, .text = text } }, text);
    }

    /// A line that is not an error record, at the verbosity its prefix
    /// implies.
    pub fn textLine(l: *Log, text: []const u8) void {
        const rec: Record = .{ .msg = .{ .level = levelOf(text), .text = text } };
        l.tee(rec);
        l.show(rec, text);
    }

    /// `textLine` into `w`, which is not stderr: the `msg` record under
    /// internal-json, else the text as Nix filters it. The sink gets the
    /// record either way.
    pub fn writeLine(l: *Log, w: *std.Io.Writer, text: []const u8) !void {
        const rec: Record = .{ .msg = .{ .level = levelOf(text), .text = text } };
        l.tee(rec);
        try l.writeShown(w, rec, text, if (l.isJson()) l.sessionId() else "");
    }

    /// A lint warning, `warning: [NAME] MSG` and maybe `\n  at POS`: the form
    /// that goes to stderr, and the record that a cache entry keeps. The
    /// caller owns both.
    pub fn lint(l: *Log, text: []const u8, site: ?Site) !struct { shown: []u8, record: []u8 } {
        const rest = if (std.mem.startsWith(u8, text, "warning: ")) text["warning: ".len..] else text;
        var raw = rest;
        var pos: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, "\n  at ")) |i| {
            raw = rest[0..i];
            pos = rest[i + "\n  at ".len ..];
        }
        const rep: Report = .{ .code = "lint", .level = 1, .raw = raw, .pos = pos, .site = site };
        const rec = rep.record(l, text);
        var buf: std.Io.Writer.Allocating = .init(l.gpa);
        defer buf.deinit();
        try rec.write(&buf.writer, null);
        const record = try buf.toOwnedSlice();
        errdefer l.gpa.free(record);
        return .{ .shown = try l.render(rec, text), .record = record };
    }

    /// `rec` as an `@nix` line under internal-json, else `text`; either way
    /// the `json-log-path` file gets the record. The caller owns the result.
    fn render(l: *Log, rec: Record, text: []const u8) ![]u8 {
        l.tee(rec);
        if (!l.isJson()) return l.gpa.dupe(u8, text);
        var buf: std.Io.Writer.Allocating = .init(l.gpa);
        defer buf.deinit();
        try buf.writer.writeAll("@nix ");
        try rec.write(&buf.writer, l.sessionId());
        return buf.toOwnedSlice();
    }

    /// The warnings a cache entry recorded, one record on each line, as
    /// `lint` puts them out. The caller owns the result.
    pub fn replayLints(l: *Log, recorded: []const u8) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(l.gpa);
        defer out.deinit();
        var lines = std.mem.splitScalar(u8, recorded, '\n');
        while (lines.next()) |ln| {
            if (ln.len == 0) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, l.gpa, ln, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const rec: Record = .{ .parsed = .{ .obj = &parsed.value.object, .a = parsed.arena.allocator() } };
            l.tee(rec);
            if (l.isJson()) {
                try out.writer.writeAll("@nix ");
                try rec.write(&out.writer, l.sessionId());
            } else try out.writer.writeAll(switch (parsed.value.object.get("msg") orelse .null) {
                .string => |m| m,
                else => "",
            });
            try out.writer.writeByte('\n');
        }
        return out.toOwnedSlice();
    }

    /// `warning: RAW`, a level-1 record with its own code.
    pub fn warning(l: *Log, code: []const u8, raw: []const u8) void {
        var stack: [512]u8 = undefined;
        var bf: std.heap.BufferFirstAllocator = .init(&stack, l.gpa);
        const a = bf.allocator();
        const text = std.fmt.allocPrint(a, "warning: {s}", .{raw}) catch return;
        defer a.free(text);
        l.report(.{ .code = code, .level = 1, .raw = raw }, text);
    }

    /// What made a tracing-cache entry stale, as `re-evaluating: RAW`.
    /// Level 3: nothing is wrong. In classic mode only `json-log-path` gets
    /// it: Nix invalidates its own evaluation cache without a word.
    pub fn invalidated(l: *Log, raw: []const u8) void {
        var stack: [512]u8 = undefined;
        var bf: std.heap.BufferFirstAllocator = .init(&stack, l.gpa);
        const a = bf.allocator();
        const text = std.fmt.allocPrint(a, "re-evaluating: {s}", .{raw}) catch return;
        defer a.free(text);
        const rep: Report = .{ .code = "cache-invalidated", .level = 3, .raw = raw };
        const rec = rep.record(l, text);
        if (l.isClassic()) l.tee(rec) else l.emit(rec, text);
    }

    /// A hash that `fix-hashes` rewrote at `pos`, `file:line:col`, which is
    /// byte `at` of the file before the edit.
    pub fn fixed(l: *Log, pos: []const u8, at: usize, old: []const u8, new: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = std.fmt.allocPrint(a, "fixed: {s}: '{s}' is now '{s}'", .{ pos, old, new }) catch return;
        const rep = fixedReport(a, pos, at, old, new) catch return;
        l.report(rep, text);
    }

    /// `rep` with `text` as its `msg`, to stderr and the sink.
    fn report(l: *Log, rep: Report, text: []const u8) void {
        l.emit(rep.record(l, text), text);
    }

    /// A failed build: its record under internal-json, else `text`, if any;
    /// the renderer prints its own.
    pub fn buildFailed(l: *Log, pos: ?[]const u8, reason: []const u8, exit: i32, text: ?[]const u8) void {
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const r = buildReport(a, pos, reason, exit) catch return;
        // the two hashes and what to do about them do not fit the renderer's
        // one-line verdict, and nix prints them
        var own: ?[]const u8 = null;
        if (std.mem.eql(u8, r.code, "hash-mismatch")) if (mismatch(r.raw)) |m| {
            l.pushMismatch(m.specified, m.got);
            if (l.wanted(r.raw)) return;
            const t = r.text(a) catch return;
            own = if (r.hint) |h| std.fmt.allocPrint(a, "{s}\n       {s}", .{ t, h }) catch return else t;
        };
        const full = r.text(a) catch return;
        l.emit(r.record(l, full), text orelse own);
    }

    // Hash mismatches.

    /// `iets prefetch` builds a derivation whose hash is wrong on purpose: a
    /// mismatch of a derivation called `name` is its answer, not a failure.
    pub fn wantMismatch(l: *Log, name: []const u8) !void {
        const w = try std.fmt.allocPrint(l.gpa, "-{s}.drv", .{name});
        l.mismatch_lock.lockUncancelable(l.io);
        defer l.mismatch_lock.unlock(l.io);
        if (l.want_mismatch) |old| l.gpa.free(old);
        l.want_mismatch = w;
    }

    /// Whether `text` is about the derivation `wantMismatch` named.
    fn wanted(l: *Log, text: []const u8) bool {
        l.mismatch_lock.lockUncancelable(l.io);
        defer l.mismatch_lock.unlock(l.io);
        const w = l.want_mismatch orelse return false;
        return std.mem.indexOf(u8, text, w) != null;
    }

    /// The daemon reports a resolved derivation's mismatch as a line of its
    /// own, not as the build's result, so the line is read here too. The
    /// pair is only a candidate: `resolveMismatches` keeps the ones that
    /// name a fixed-output derivation of the plan.
    pub fn noteMismatch(l: *Log, text: []const u8) void {
        if (std.mem.indexOf(u8, text, mismatch_text) == null) return;
        const plain = stripAnsi(l.gpa, text) catch return;
        defer l.gpa.free(plain);
        if (mismatch(plain)) |m| l.pushMismatch(m.specified, m.got);
    }

    /// One `(specified, got)` pair, skipping one that is already there.
    fn pushMismatch(l: *Log, specified: []const u8, got: []const u8) void {
        l.mismatch_lock.lockUncancelable(l.io);
        defer l.mismatch_lock.unlock(l.io);
        for (l.pending.items) |p| if (std.mem.eql(u8, p.specified, specified) and std.mem.eql(u8, p.got, got)) return;
        const s = l.gpa.dupe(u8, specified) catch return;
        const g = l.gpa.dupe(u8, got) catch {
            l.gpa.free(s);
            return;
        };
        l.pending.append(l.gpa, .{ .specified = s, .got = g }) catch freePair(l.gpa, .{ .specified = s, .got = g });
    }

    /// Decides the candidates: `planned` says whether a `specified` hash is
    /// the output hash of a fixed-output derivation the client is building.
    /// Returns how many were kept.
    pub fn resolveMismatches(l: *Log, ctx: anytype, comptime planned: fn (@TypeOf(ctx), []const u8) bool) usize {
        l.mismatch_lock.lockUncancelable(l.io);
        defer l.mismatch_lock.unlock(l.io);
        var kept: usize = 0;
        for (l.pending.items) |m| {
            if (!planned(ctx, m.specified)) {
                freePair(l.gpa, m);
                continue;
            }
            kept += 1;
            const dup = for (l.mismatches.items) |x| {
                if (std.mem.eql(u8, x.specified, m.specified) and std.mem.eql(u8, x.got, m.got)) break true;
            } else false;
            if (dup) freePair(l.gpa, m) else l.mismatches.append(l.gpa, m) catch freePair(l.gpa, m);
        }
        l.pending.clearRetainingCapacity();
        return kept;
    }

    /// The `(specified, got)` pairs of the hash mismatches reported since
    /// the last call; the caller frees them with `freePairs`.
    pub fn takeMismatches(l: *Log) ![]Pair {
        l.mismatch_lock.lockUncancelable(l.io);
        defer l.mismatch_lock.unlock(l.io);
        return l.mismatches.toOwnedSlice(l.gpa);
    }

    pub fn freePairs(l: *Log, ps: []Pair) void {
        for (ps) |p| freePair(l.gpa, p);
        l.gpa.free(ps);
    }
};

fn freePair(gpa: Allocator, p: Pair) void {
    gpa.free(p.specified);
    gpa.free(p.got);
}

/// An activity of iets's own.
pub const Activity = struct {
    log: *Log,
    id: u64,

    pub fn result(a: Activity, ty: u64, f: []const Field) void {
        a.log.result(a.id, ty, f);
    }

    pub fn end(a: Activity) void {
        a.log.stop(a.id);
    }
};

/// RFC 9562 version 7: 48 bits of Unix milliseconds, then random bits.
pub fn uuidV7(ms: u64, rnd: [10]u8) [36]u8 {
    var b: [16]u8 = undefined;
    std.mem.writeInt(u48, b[0..6], @truncate(ms), .big);
    @memcpy(b[6..], &rnd);
    b[6] = 0x70 | (b[6] & 0x0f);
    b[8] = 0x80 | (b[8] & 0x3f);
    var out: [36]u8 = undefined;
    const hex = std.fmt.bytesToHex(b, .lower);
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

/// One record of logging.cc:JSONLogger. Rust iets writes a record's keys in
/// byte order, so each kind writes its keys in that order, straight into
/// the writer.
pub const Record = union(enum) {
    start: struct { id: u64, level: u64, ty: u64, text: []const u8, fields: []const Field, parent: u64 },
    stop: u64,
    result: struct { id: u64, ty: u64, fields: []const Field },
    msg: struct { level: u64, text: []const u8 },
    /// An error or warning, `text` its `msg`; the trace only with
    /// `--show-trace`.
    report: struct { rep: Report, text: []const u8, trace: bool },
    /// A record read back (`replayLints`), which grows in its parse arena.
    parsed: struct { obj: *std.json.ObjectMap, a: Allocator },

    /// The record, with `sid` when there is one.
    pub fn write(rec: Record, w: *std.Io.Writer, sid: ?[]const u8) !void {
        switch (rec) {
            .start => |s| {
                try w.writeAll("{\"action\":\"start\"");
                try writeFields(w, s.fields);
                try w.print(",\"id\":{d},\"level\":{d},\"parent\":{d}", .{ s.id, s.level, s.parent });
                try writeSid(w, sid);
                try w.writeAll(",\"text\":");
                try writeString(w, s.text);
                try w.print(",\"type\":{d}}}", .{s.ty});
            },
            .stop => |id| {
                try w.print("{{\"action\":\"stop\",\"id\":{d}", .{id});
                try writeSid(w, sid);
                try w.writeByte('}');
            },
            .result => |r| {
                try w.writeAll("{\"action\":\"result\"");
                try writeFields(w, r.fields);
                try w.print(",\"id\":{d}", .{r.id});
                try writeSid(w, sid);
                try w.print(",\"type\":{d}}}", .{r.ty});
            },
            .msg => |m| {
                try w.print("{{\"action\":\"msg\",\"level\":{d},\"msg\":", .{m.level});
                try writeString(w, m.text);
                try writeSid(w, sid);
                try w.writeByte('}');
            },
            .report => |r| try r.rep.writeRecord(w, r.text, r.trace, sid),
            .parsed => |p| {
                if (sid) |x| try p.obj.put(p.a, "sid", .{ .string = x });
                try writeValue(w, p.a, .{ .object = p.obj.* });
            },
        }
    }
};

fn writeSid(w: *std.Io.Writer, sid: ?[]const u8) !void {
    const s = sid orelse return;
    try w.writeAll(",\"sid\":");
    try writeString(w, s);
}

/// `"fields":[...]`, when there are any.
fn writeFields(w: *std.Io.Writer, f: []const Field) !void {
    if (f.len == 0) return;
    try w.writeAll(",\"fields\":[");
    for (f, 0..) |x, i| {
        if (i > 0) try w.writeByte(',');
        switch (x) {
            .str => |s| try writeString(w, s),
            .int => |n| try w.print("{d}", .{n}),
        }
    }
    try w.writeByte(']');
}

fn writeOptStr(w: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |x| try writeString(w, x) else try w.writeAll("null");
}

fn writeOptInt(w: *std.Io.Writer, n: ?u32) !void {
    if (n) |x| try w.print("{d}", .{x}) else try w.writeAll("null");
}

/// A parsed value, objects with their keys in byte order.
pub fn writeValue(w: *std.Io.Writer, a: Allocator, v: std.json.Value) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeString(w, s),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |x, i| {
                if (i > 0) try w.writeByte(',');
                try writeValue(w, a, x);
            }
            try w.writeByte(']');
        },
        .object => |o| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(a);
            try keys.appendSlice(a, o.keys());
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            try w.writeByte('{');
            for (keys.items, 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try writeString(w, k);
                try w.writeByte(':');
                try writeValue(w, a, o.get(k).?);
            }
            try w.writeByte('}');
        },
    }
}

/// A place in a file as byte offsets, and the text to put there. The site
/// of a lint finding and the hash that `fix-hashes` wrote have this shape.
pub const Site = struct {
    start: u64,
    /// The offset after the last byte.
    end: u64,
    /// The text that replaces those bytes, when the record has an edit.
    replacement: ?[]const u8 = null,
};

pub const TraceEntry = struct { msg: []const u8, pos: ?[]const u8 = null };

/// One error (or, at level 1, warning) for stderr.
pub const Report = struct {
    /// The stable code of docs/reference/errors.md.
    code: []const u8,
    level: u8 = 0,
    /// The message, without `error: `.
    raw: []const u8,
    /// `file:line:col`, as Nix prints a position.
    pos: ?[]const u8 = null,
    /// Innermost first, each with its position.
    trace: []const TraceEntry = &.{},
    /// What to do about it. The text shows it for a usage or unsupported
    /// error only.
    hint: ?[]const u8 = null,
    /// Where it is in the file as bytes, and the edit, when they are known.
    site: ?Site = null,

    /// The text Nix-style commands print, without the last newline.
    pub fn writeText(r: Report, w: *std.Io.Writer) !void {
        try w.print("error: {s}", .{r.raw});
        if (r.pos) |p| try w.print("\n       at {s}", .{p});
        for (r.trace) |t| {
            if (t.pos) |p| try w.print("\n       … {s} at {s}", .{ t.msg, p }) else try w.print("\n       … {s}", .{t.msg});
        }
        if (r.hint) |h| if (std.mem.eql(u8, r.code, "usage") or std.mem.eql(u8, r.code, "unsupported")) {
            try w.writeByte('\n');
            try w.writeAll(h);
        };
    }

    pub fn text(r: Report, a: Allocator) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(a);
        defer buf.deinit();
        try r.writeText(&buf.writer);
        return buf.toOwnedSlice();
    }

    /// logging.cc:JSONLogger::logEI; `text` is the `msg` field. The trace
    /// goes in under `--show-trace` only.
    pub fn record(r: Report, l: ?*Log, text_: []const u8) Record {
        const trace = if (l) |lg| lg.show_trace.load(.monotonic) else false;
        return .{ .report = .{ .rep = r, .text = text_, .trace = trace } };
    }

    fn writeRecord(r: Report, w: *std.Io.Writer, msg_: []const u8, trace: bool, sid: ?[]const u8) !void {
        const p: Pos = .parse(r.pos);
        try w.writeAll("{\"action\":\"msg\",\"code\":");
        try writeString(w, r.code);
        try w.writeAll(",\"column\":");
        try writeOptInt(w, p.column);
        if (r.site) |s| try w.print(",\"end\":{d}", .{s.end});
        try w.writeAll(",\"file\":");
        try writeOptStr(w, r.pos);
        if (r.hint) |h| {
            try w.writeAll(",\"hint\":");
            try writeString(w, h);
        }
        try w.print(",\"level\":{d},\"line\":", .{r.level});
        try writeOptInt(w, p.line);
        try w.writeAll(",\"msg\":");
        try writeString(w, msg_);
        try w.writeAll(",\"raw_msg\":");
        try writeString(w, r.raw);
        if (r.site) |s| if (s.replacement) |x| {
            try w.writeAll(",\"replacement\":");
            try writeString(w, x);
        };
        try writeSid(w, sid);
        if (r.site) |s| try w.print(",\"start\":{d}", .{s.start});
        if (trace and r.trace.len > 0) {
            try w.writeAll(",\"trace\":[");
            for (r.trace, 0..) |t, i| {
                if (i > 0) try w.writeByte(',');
                const tp: Pos = .parse(t.pos);
                try w.writeAll("{\"column\":");
                try writeOptInt(w, tp.column);
                try w.writeAll(",\"file\":");
                try writeOptStr(w, t.pos);
                try w.writeAll(",\"line\":");
                try writeOptInt(w, tp.line);
                try w.writeAll(",\"raw_msg\":");
                try writeString(w, t.msg);
                try w.writeByte('}');
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }

    /// Prints the report and returns the exit code. Classic mode always
    /// uses 1, as Nix does.
    pub fn emit(r: Report, l: *Log) u8 {
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        const t = r.text(arena.allocator()) catch return 1;
        l.emit(r.record(l, t), t);
        if (l.command == null) return 1;
        if (std.mem.eql(u8, r.code, "usage")) return 2;
        if (std.mem.eql(u8, r.code, "unsupported")) return 3;
        return 1;
    }
};

/// logging.cc:to_json(Pos): the line and column come off the end of `pos`.
const Pos = struct {
    line: ?u32 = null,
    column: ?u32 = null,

    fn parse(pos: ?[]const u8) Pos {
        const p = pos orelse return .{};
        const c = std.mem.lastIndexOfScalar(u8, p, ':') orelse return .{};
        const rest = p[0..c];
        const b = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return .{};
        return .{
            .line = std.fmt.parseInt(u32, rest[b + 1 ..], 10) catch return .{},
            .column = std.fmt.parseInt(u32, p[c + 1 ..], 10) catch return .{},
        };
    }
};

/// build-result.cc:failingExitStatus of one failed build, from its
/// worker-protocol status. The daemon sends a hash mismatch as
/// OutputRejected, so its message tells it apart.
pub fn buildExit(status: u64, m: []const u8) i32 {
    return switch (status) {
        // 10 is DependencyFailed: a goal of the run failed, which is the same
        // flag Nix's worker sets for the build that failed itself
        3, 4, 10 => 100,
        8 => 101,
        5 => if (std.mem.indexOf(u8, m, mismatch_text) != null) 102 else 1,
        12 => 104,
        else => 1,
    };
}

/// failingExitStatus over several builds: the flags of the special codes
/// combine, any other failure is 1.
pub fn combineExit(a: i32, b: i32) i32 {
    if (a >= 100 and b >= 100) return a | b;
    return @max(a, b);
}

/// The `specified` and `got` hashes of a fixed-output hash mismatch
/// message; slices of `raw`.
pub fn mismatch(raw: []const u8) ?struct { specified: []const u8, got: []const u8 } {
    const field = struct {
        fn f(r: []const u8, k: []const u8) ?[]const u8 {
            var lines = std.mem.splitScalar(u8, r, '\n');
            while (lines.next()) |l| {
                const t = std.mem.trim(u8, l, " \t\r");
                if (std.mem.startsWith(u8, t, k)) return std.mem.trim(u8, t[k.len..], " \t\r");
            }
            return null;
        }
    }.f;
    return .{ .specified = field(raw, "specified:") orelse return null, .got = field(raw, "got:") orelse return null };
}

fn fixedReport(a: Allocator, pos: []const u8, at: usize, old: []const u8, new: []const u8) !Report {
    return .{
        .code = "hash-fixed",
        .level = 3,
        .raw = try std.fmt.allocPrint(a, "'{s}' is now '{s}'", .{ old, new }),
        .pos = pos,
        .site = .{ .start = at, .end = at + old.len, .replacement = new },
    };
}

/// A failed build as a record; `reason` is `status N: MSG` or a plain
/// message, `pos` where the derivation was defined.
fn buildReport(a: Allocator, pos: ?[]const u8, reason: []const u8, exit: i32) !Report {
    var m = reason;
    if (std.mem.indexOf(u8, reason, ": ")) |i| if (std.mem.startsWith(u8, reason[0..i], "status ")) {
        m = reason[i + 2 ..];
    };
    const raw = try stripAnsi(a, m);
    var r: Report = .{ .code = "build-failed", .raw = std.mem.trimEnd(u8, raw, " \t\r\n"), .pos = pos };
    if (exit == 102) if (mismatch(raw)) |mm| {
        r.code = "hash-mismatch";
        r.hint = try std.fmt.allocPrint(a, "set the expected hash to '{s}'", .{mm.got});
    };
    return r;
}

/// A build result's message as one line: its first line, and the two
/// hashes of a fixed-output mismatch, which say what to fix.
pub fn reasonLine(a: Allocator, raw: []const u8) ![]u8 {
    var it = std.mem.splitScalar(u8, raw, '\n');
    const first = std.mem.trimEnd(u8, it.first(), " \t\r");
    if (mismatch(raw)) |m| return std.fmt.allocPrint(a, "{s} specified: {s}, got: {s}", .{ first, m.specified, m.got });
    return a.dupe(u8, first);
}

/// Scans a CSI sequence from the byte after `ESC [`: parameter bytes,
/// intermediate bytes, one final byte. Gives the index after it and the
/// final byte, 0 when there is none.
fn csi(b: []const u8, start: usize) struct { usize, u8 } {
    var i = start;
    while (i < b.len and b[i] >= 0x30 and b[i] <= 0x3f) i += 1;
    while (i < b.len and b[i] >= 0x20 and b[i] <= 0x2f) i += 1;
    if (i < b.len and b[i] >= 0x40 and b[i] <= 0x7e) return .{ i + 1, b[i] };
    return .{ i, 0 };
}

/// The text of `s` between its ECMA-048 escape sequences, chunk by chunk.
pub const Plain = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(p: *Plain) ?[]const u8 {
        const s = p.s;
        while (p.i < s.len) {
            if (s[p.i] != 0x1b) {
                const start = p.i;
                p.i = std.mem.indexOfScalarPos(u8, s, p.i, 0x1b) orelse s.len;
                return s[start..p.i];
            }
            p.i += 1;
            if (p.i < s.len) {
                const c = s[p.i];
                if (c == '[') {
                    p.i = csi(s, p.i + 1)[0];
                } else if ((c >= 0x40 and c <= 0x5a) or (c >= 0x5c and c <= 0x5f)) {
                    // 7-bit C1 Fe other than CSI
                    p.i += 1;
                }
            }
        }
        return null;
    }
};

/// `s` without its ECMA-048 escape sequences.
pub fn stripAnsi(a: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(a, s.len);
    errdefer out.deinit(a);
    var it: Plain = .{ .s = s };
    while (it.next()) |c| out.appendSliceAssumeCapacity(c);
    return out.toOwnedSlice(a);
}

/// The verbosity a line's prefix implies. The daemon's own messages arrive
/// coloured, so the prefix is read past the escapes.
fn levelOf(text: []const u8) u64 {
    const longest = "evaluation warning:";
    var buf: [longest.len]u8 = undefined;
    var n: usize = 0;
    var it: Plain = .{ .s = text };
    while (n < buf.len) {
        const c = it.next() orelse break;
        const k = @min(c.len, buf.len - n);
        @memcpy(buf[n..][0..k], c[0..k]);
        n += k;
    }
    const plain = buf[0..n];
    const starts = std.mem.startsWith;
    if (starts(u8, plain, "error:") or starts(u8, plain, "trace:")) return lvl_error;
    if (starts(u8, plain, "warning:") or starts(u8, plain, longest)) return 1;
    return lvl_info;
}

/// terminal.cc:filterANSIEscapes, what every line Nix writes to stderr goes
/// through: only a colour sequence survives, and only when the reader is a
/// terminal. Cursor movement, a clear screen and an OSC string never do. A
/// tab goes to the next multiple of 8 of the characters written so far,
/// newlines included, as Rust iets counts them.
pub fn filterAnsiInto(w: *std.Io.Writer, s: []const u8, filter_all: bool) !void {
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        switch (s[i]) {
            0x1b => {
                const start = i;
                i += 1;
                var last: u8 = 0;
                if (i < s.len) {
                    const c = s[i];
                    if (c == '[') {
                        i, last = csi(s, i + 1);
                    } else if (c == ']') {
                        i += 1;
                        while (i < s.len and s[i] != 0x1b and s[i] != 0x07) i += 1;
                        if (i < s.len) {
                            const v = s[i];
                            i += 1;
                            if (v == 0x1b and i < s.len and s[i] == '\\') i += 1;
                        }
                    } else if (c >= 0x40 and c <= 0x5f) {
                        i += 1;
                    }
                }
                if (!filter_all and last == 'm') try w.writeAll(s[start..i]);
            },
            '\t' => {
                i += 1;
                while (true) {
                    col += 1;
                    try w.writeByte(' ');
                    if (col % 8 == 0) break;
                }
            },
            '\r', 0x07 => i += 1,
            else => {
                const start = i;
                while (i < s.len and s[i] != 0x1b and s[i] != '\t' and s[i] != '\r' and s[i] != 0x07) i += 1;
                const chunk = s[start..i];
                col += std.unicode.utf8CountCodepoints(chunk) catch chunk.len;
                try w.writeAll(chunk);
            },
        }
    }
}

const testing = std.testing;

/// A terminal of a given size, and the screen what is written shows.
const Screen = struct {
    emu: display.Emu,
    size: ?display.Size,
    guards: std.ArrayList(usize) = .empty,
    w: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const s: *Screen = @fieldParentPtr("w", w);
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            s.emu.feed(d) catch return error.WriteFailed;
            n += d.len;
        }
        for (0..splat) |_| {
            s.emu.feed(data[data.len - 1]) catch return error.WriteFailed;
            n += data[data.len - 1].len;
        }
        return n;
    }

    const vtable: Term.VTable = .{
        .size = struct {
            fn f(c: ?*anyopaque) ?display.Size {
                const s: *Screen = @ptrCast(@alignCast(c.?));
                return s.size;
            }
        }.f,
        .cursor = struct {
            fn f(c: ?*anyopaque) ?[2]usize {
                const s: *Screen = @ptrCast(@alignCast(c.?));
                const at = s.emu.cursor();
                return .{ at[0] + 1, at[1] + 1 };
            }
        }.f,
        .guard = struct {
            fn f(c: ?*anyopaque, top: usize) void {
                const s: *Screen = @ptrCast(@alignCast(c.?));
                s.guards.append(testing.allocator, top) catch {};
            }
        }.f,
    };

    fn create(cols: usize, rows: usize) !*Screen {
        const s = try testing.allocator.create(Screen);
        s.* = .{ .emu = try .init(testing.allocator, rows, cols), .size = .{ cols, rows } };
        return s;
    }

    fn destroy(s: *Screen) void {
        s.emu.deinit();
        s.guards.deinit(testing.allocator);
        testing.allocator.destroy(s);
    }

    fn log(s: *Screen) Log {
        var l: Log = .init(testing.allocator, testing.io, .{});
        l.out.w = &s.w;
        l.out.term = .{ .ctx = s, .vtable = &vtable };
        return l;
    }

    fn screenRows(s: *Screen) ![][]u8 {
        return s.emu.screen();
    }

    fn resize(s: *Screen, cols: usize, rs: usize) !void {
        s.size = .{ cols, rs };
        try s.emu.resize(rs, cols);
    }
};

fn contains(rows: []const []const u8, what: []const u8) bool {
    for (rows) |r| if (std.mem.eql(u8, r, what)) return true;
    return false;
}

test "a region stays under the output that scrolls above it" {
    const s = try Screen.create(40, 8);
    defer s.destroy();
    var l = s.log();
    defer l.deinit();
    try l.setRegion(&.{ "one", "two" });
    var buf: [16]u8 = undefined;
    for (0..12) |i| l.errln(try std.fmt.bufPrint(&buf, "out {d}", .{i}));
    {
        const rows = try s.screenRows();
        defer s.emu.freeScreen(rows);
        for (0..6) |i| try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "out {d}", .{i + 6}), rows[i]);
        try testing.expectEqualStrings("one", rows[6]);
        try testing.expectEqualStrings("two", rows[7]);
    }
    try l.setRegion(&.{});
    l.errln("end");
    const rows = try s.screenRows();
    defer s.emu.freeScreen(rows);
    try testing.expect(!contains(rows, "one") and !contains(rows, "two"));
    try testing.expect(contains(rows, "end"));
    // nothing is left to clear on a signal
    try testing.expectEqual(0, s.guards.items[s.guards.items.len - 1]);
}

test "the status line goes under the region" {
    const s = try Screen.create(40, 8);
    defer s.destroy();
    var l = s.log();
    defer l.deinit();
    try l.setRegion(&.{"region"});
    try l.setStatus("status");
    {
        const rows = try s.screenRows();
        defer s.emu.freeScreen(rows);
        try testing.expectEqualStrings("region", rows[0]);
        try testing.expectEqualStrings("status", rows[1]);
    }
    try l.setStatus("");
    const rows = try s.screenRows();
    defer s.emu.freeScreen(rows);
    try testing.expectEqualStrings("region", rows[0]);
    try testing.expectEqualStrings("", rows[1]);
}

test "a resize redraws the region once" {
    const s = try Screen.create(40, 10);
    defer s.destroy();
    var l = s.log();
    defer l.deinit();
    try l.setRegion(&.{ "HEADER", "run" });
    var buf: [16]u8 = undefined;
    for (0..6) |i| l.errln(try std.fmt.bufPrint(&buf, "out {d}", .{i}));
    try s.resize(20, 6);
    try l.setRegion(&.{ "HEADER", "run" });
    try l.setRegion(&.{ "HEADER", "run" });
    const rows = try s.screenRows();
    defer s.emu.freeScreen(rows);
    var n: usize = 0;
    for (rows) |r| {
        if (std.mem.eql(u8, r, "HEADER")) n += 1;
    }
    try testing.expectEqual(1, n);
    try testing.expectEqualStrings("HEADER", rows[4]);
    try testing.expectEqualStrings("run", rows[5]);
    try testing.expectEqualStrings("out 5", rows[3]);
}

test "a pause takes the view down for a prompt" {
    const s = try Screen.create(40, 8);
    defer s.destroy();
    var l = s.log();
    defer l.deinit();
    try l.setRegion(&.{"region"});
    l.pause(true);
    {
        const rows = try s.screenRows();
        defer s.emu.freeScreen(rows);
        try testing.expect(!contains(rows, "region"));
    }
    l.err("Password: ");
    {
        const rows = try s.screenRows();
        defer s.emu.freeScreen(rows);
        try testing.expectEqualStrings("Password:", rows[0]);
    }
    l.pause(false);
    const rows = try s.screenRows();
    defer s.emu.freeScreen(rows);
    try testing.expect(contains(rows, "region"));
}

test "a half line waits for its newline" {
    const s = try Screen.create(40, 8);
    defer s.destroy();
    var l = s.log();
    defer l.deinit();
    try l.setRegion(&.{"region"});
    l.err("abc");
    {
        const rows = try s.screenRows();
        defer s.emu.freeScreen(rows);
        for (rows) |r| try testing.expect(std.mem.indexOf(u8, r, "abc") == null);
    }
    l.err("def\n");
    {
        const rows = try s.screenRows();
        defer s.emu.freeScreen(rows);
        try testing.expectEqualStrings("abcdef", rows[0]);
    }
    try l.setRegion(&.{});
    const rows = try s.screenRows();
    defer s.emu.freeScreen(rows);
    var n: usize = 0;
    for (rows) |r| {
        if (std.mem.indexOf(u8, r, "abcdef") != null) n += 1;
    }
    try testing.expectEqual(1, n);
}

test "without a terminal output is plain" {
    const s = try Screen.create(40, 8);
    defer s.destroy();
    var l = s.log();
    defer l.deinit();
    s.size = null;
    try l.setRegion(&.{"region"});
    l.errln("plain");
    const rows = try s.screenRows();
    defer s.emu.freeScreen(rows);
    try testing.expectEqualStrings("plain", rows[0]);
    try testing.expect(!contains(rows, "region"));
}

test "ansi stripping" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "\x1b[1;32mgreen\x1b[0m", "green" },
        .{ "plain", "plain" },
        // `]` is one of the 7-bit C1 Fe bytes, so it goes with the ESC
        .{ "a\x1b]0;titl", "a0;titl" },
    };
    for (cases) |c| {
        const got = try stripAnsi(a, c[0]);
        defer a.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

/// A log that writes into memory.
const Mem = struct {
    buf: std.Io.Writer.Allocating,
    l: Log,

    fn create() !*Mem {
        const m = try testing.allocator.create(Mem);
        m.* = .{ .buf = .init(testing.allocator), .l = .init(testing.allocator, testing.io, .{}) };
        m.l.out.w = &m.buf.writer;
        m.l.stderr_tty = false;
        m.l.sink_state = .none;
        return m;
    }

    fn destroy(m: *Mem) void {
        m.l.deinit();
        m.buf.deinit();
        testing.allocator.destroy(m);
    }
};

fn recordOf(l: ?*Log, r: Report, text_: []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try r.record(l, text_).write(&buf.writer, null);
    return buf.toOwnedSlice();
}

test "record is nix logEI plus code and hint" {
    const a = testing.allocator;
    const r: Report = .{
        .code = "missing-attr",
        .raw = "attribute 'abd' missing",
        .pos = "/a/b.nix:3:7",
        .trace = &.{.{ .msg = "while calling 'f'", .pos = "«string»:1:9" }},
        .hint = "did you mean 'abc'?",
    };
    const t = try r.text(a);
    defer a.free(t);
    try testing.expectEqualStrings("error: attribute 'abd' missing\n       at /a/b.nix:3:7\n       … while calling 'f' at «string»:1:9", t);
    const want =
        \\{"action":"msg","code":"missing-attr","column":7,"file":"/a/b.nix:3:7","hint":"did you mean 'abc'?","level":0,"line":3,"msg":"error: attribute 'abd' missing\n       at /a/b.nix:3:7\n       … while calling 'f' at «string»:1:9","raw_msg":"attribute 'abd' missing"}
    ;
    const got = try recordOf(null, r, t);
    defer a.free(got);
    try testing.expectEqualStrings(want, got);
    const m = try Mem.create();
    defer m.destroy();
    m.l.setShowTrace();
    const with = try recordOf(&m.l, r, t);
    defer a.free(with);
    const tr =
        \\"trace":[{"column":9,"file":"«string»:1:9","line":1,"raw_msg":"while calling 'f'"}]
    ;
    try testing.expect(std.mem.indexOf(u8, with, tr) != null);
}

test "text shows the hint of an unsupported error" {
    const r: Report = .{ .code = "unsupported", .raw = "builtins.fetchGit is not supported", .hint = "use builtins.fetchTree" };
    const t = try r.text(testing.allocator);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("error: builtins.fetchGit is not supported\nuse builtins.fetchTree", t);
}

test "a session id is a uuid v7" {
    var r1: [10]u8 = undefined;
    var r2: [10]u8 = undefined;
    sys.random(&r1);
    sys.random(&r2);
    const a = uuidV7(0x019e_037b_f603, r1);
    const b = uuidV7(0x019e_037b_f603, r2);
    try testing.expect(std.mem.startsWith(u8, &a, "019e037b-f603-7"));
    try testing.expect(std.mem.indexOfScalar(u8, "89ab", a[19]) != null);
    var parts = std.mem.splitScalar(u8, &a, '-');
    for ([_]usize{ 8, 4, 4, 4, 12 }) |n| try testing.expectEqual(n, parts.next().?.len);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    const m = try Mem.create();
    defer m.destroy();
    m.l.json.store(true, .monotonic);
    m.l.msg(3, "x");
    const sid = m.l.sessionId();
    try testing.expect(std.mem.indexOf(u8, m.buf.written(), sid) != null);
}

test "record without position" {
    const got = try recordOf(null, .{ .code = "usage", .raw = "unknown flag '--x'" }, "m");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\{"action":"msg","code":"usage","column":null,"file":null,"level":0,"line":null,"msg":"m","raw_msg":"unknown flag '--x'"}
    , got);
}

test "lint warning is a level 1 record" {
    const a = testing.allocator;
    const m = try Mem.create();
    defer m.destroy();
    const text_ = "warning: [url-literal] URL literal\n  at /a.nix:2:5";
    const want =
        \\{"action":"msg","code":"lint","column":5,"file":"/a.nix:2:5","level":1,"line":2,"msg":"warning: [url-literal] URL literal\n  at /a.nix:2:5","raw_msg":"[url-literal] URL literal"}
    ;
    const r1 = try m.l.lint(text_, null);
    defer a.free(r1.shown);
    defer a.free(r1.record);
    try testing.expectEqualStrings(text_, r1.shown);
    try testing.expectEqualStrings(want, r1.record);
    const r2 = try m.l.lint(text_, .{ .start = 9, .end = 19, .replacement = "\"http://a.b\"" });
    defer a.free(r2.shown);
    defer a.free(r2.record);
    const tail =
        \\"raw_msg":"[url-literal] URL literal","replacement":"\"http://a.b\"","start":9}
    ;
    try testing.expect(std.mem.indexOf(u8, r2.record, "\"end\":19,") != null);
    try testing.expect(std.mem.endsWith(u8, r2.record, tail));
    // a cache entry gives the text back, or the records under internal-json
    const kept = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ want, r2.record });
    defer a.free(kept);
    const twice = try std.fmt.allocPrint(a, "{s}\n{s}\n", .{ text_, text_ });
    defer a.free(twice);
    const back = try m.l.replayLints(kept);
    defer a.free(back);
    try testing.expectEqualStrings(twice, back);
    m.l.json.store(true, .monotonic);
    const replayed = try m.l.replayLints(kept);
    defer a.free(replayed);
    try testing.expect(std.mem.startsWith(u8, replayed, "@nix {"));
    try testing.expect(std.mem.indexOf(u8, replayed, "\"start\":9") != null);
    try testing.expectEqual(2, std.mem.count(u8, replayed, "\n"));
}

test "a fixed hash has the shape of a finding with an edit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r = try fixedReport(arena.allocator(), "/a.nix:2:11", 12, "sha256-A=", "sha256-BB=");
    const got = try recordOf(null, r, "m");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\{"action":"msg","code":"hash-fixed","column":11,"end":21,"file":"/a.nix:2:11","level":3,"line":2,"msg":"m","raw_msg":"'sha256-A=' is now 'sha256-BB='","replacement":"sha256-BB=","start":12}
    , got);
}

test "activity records are nix json logger records" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: std.Io.Writer.Allocating = .init(a);
    const fields: []const Field = &.{ .{ .str = "/nix/store/x.drv" }, .{ .str = "" }, .{ .int = 1 }, .{ .int = 1 } };
    try (Record{ .start = .{ .id = 7, .level = 3, .ty = act_build, .text = "building '/nix/store/x.drv'", .fields = fields, .parent = 0 } }).write(&buf.writer, null);
    try testing.expectEqualStrings(
        \\{"action":"start","fields":["/nix/store/x.drv","",1,1],"id":7,"level":3,"parent":0,"text":"building '/nix/store/x.drv'","type":105}
    , buf.written());
    buf.clearRetainingCapacity();
    try (Record{ .start = .{ .id = 8, .level = 0, .ty = act_realise, .text = "", .fields = &.{}, .parent = 7 } }).write(&buf.writer, null);
    try testing.expectEqualStrings(
        \\{"action":"start","id":8,"level":0,"parent":7,"text":"","type":102}
    , buf.written());
    buf.clearRetainingCapacity();
    try (Record{ .result = .{ .id = 8, .ty = res_progress, .fields = &.{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 1 }, .{ .int = 0 } } } }).write(&buf.writer, null);
    try testing.expectEqualStrings(
        \\{"action":"result","fields":[1,2,1,0],"id":8,"type":105}
    , buf.written());
    buf.clearRetainingCapacity();
    try (Record{ .stop = 8 }).write(&buf.writer, "s");
    try testing.expectEqualStrings(
        \\{"action":"stop","id":8,"sid":"s"}
    , buf.written());
    const m = try Mem.create();
    defer m.destroy();
    try testing.expectEqual(@as(u64, sys.pid()), m.l.activityId() >> 32);
    try testing.expect(m.l.activityId() != m.l.activityId());
}

test "exit status flags combine like nix" {
    try testing.expectEqual(100, buildExit(3, ""));
    try testing.expectEqual(101, buildExit(8, ""));
    try testing.expectEqual(102, buildExit(5, "hash mismatch in fixed-output derivation 'x':"));
    try testing.expectEqual(1, buildExit(5, "output rejected"));
    try testing.expectEqual(104, buildExit(12, ""));
    try testing.expectEqual(100, buildExit(10, "Build failed due to failed dependency"));
    try testing.expectEqual(101, combineExit(100, 101));
    try testing.expectEqual(108, combineExit(100, 104));
    try testing.expectEqual(102, combineExit(1, 102));
    try testing.expectEqual(1, combineExit(0, 1));
    try testing.expectEqual(0, combineExit(0, 0));
}

fn isA(want: []const u8, s: []const u8) bool {
    return std.mem.eql(u8, want, s);
}

fn always(_: void, _: []const u8) bool {
    return true;
}

fn never(_: void, _: []const u8) bool {
    return false;
}

test "a resolved copy reports its mismatch as a line" {
    const m = try Mem.create();
    defer m.destroy();
    const a = "sha256-AoAoAoAoAo=";
    const ln = "error: hash mismatch in fixed-output derivation '/nix/store/r-x.drv':\n         specified: " ++ a ++ "\n            got:    sha256-BoBoBoBoBo=";
    m.l.noteMismatch(ln);
    m.l.noteMismatch(ln);
    try testing.expectEqual(1, m.l.resolveMismatches(@as([]const u8, a), isA));
    const got = try m.l.takeMismatches();
    defer m.l.freePairs(got);
    try testing.expectEqual(1, got.len);
    try testing.expectEqualStrings(a, got[0].specified);
    try testing.expectEqualStrings("sha256-BoBoBoBoBo=", got[0].got);
    m.l.noteMismatch("error: build of resolved derivation '/nix/store/r-x.drv' failed");
    try testing.expectEqual(0, m.l.resolveMismatches({}, always));
    const none = try m.l.takeMismatches();
    defer m.l.freePairs(none);
    try testing.expectEqual(0, none.len);
}

test "a forged mismatch is dropped" {
    const m = try Mem.create();
    defer m.destroy();
    const ln = mismatch_text ++ " 'x':\n  specified: sha256-AoAoAoAoAo=\n     got:    sha256-BoBoBoBoBo=";
    m.l.noteMismatch(ln);
    try testing.expectEqual(0, m.l.resolveMismatches({}, never));
    const none = try m.l.takeMismatches();
    defer m.l.freePairs(none);
    try testing.expectEqual(0, none.len);
    // the same text as a line on stderr, as a build log line reaches it
    m.l.textLine(ln);
    try testing.expectEqual(0, m.l.resolveMismatches({}, always));
}

test "invalid utf-8 is one replacement per broken sequence" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeString(&w, "a\xe2\x82b\xffc\xf0\x9f\x98");
    try testing.expectEqualStrings("\"a\u{fffd}b\u{fffd}c\u{fffd}\"", w.buffered());
}

test "escapes are filtered the way nix filters them" {
    const a = testing.allocator;
    const coloured = "\x1b[31;1merror:\x1b[0m boom";
    const cases = [_]struct { []const u8, bool, []const u8 }{
        .{ coloured, true, "error: boom" },
        .{ coloured, false, coloured },
        // cursor movement, clear screen and OSC never survive
        .{ "a\x1b[2Jb\x1b[3Dc", false, "abc" },
        .{ "a\x1b]0;title\x07b", false, "ab" },
        .{ "a\x1b]8;;http://x\x1b\\b", false, "ab" },
        .{ "a\rb\x07", false, "ab" },
        .{ "a\tb", false, "a       b" },
        // the column counts every character before, newlines included
        .{ "error: ab\n\tx", true, "error: ab\n      x" },
    };
    for (cases) |c| {
        var got: std.Io.Writer.Allocating = .init(a);
        defer got.deinit();
        try filterAnsiInto(&got.writer, c[0], c[1]);
        try testing.expectEqualStrings(c[2], got.written());
    }
}

test "a coloured error is an error record" {
    const m = try Mem.create();
    defer m.destroy();
    m.l.json.store(true, .monotonic);
    m.l.textLine("\x1b[31;1merror:\x1b[0m boom");
    try testing.expect(std.mem.indexOf(u8, m.buf.written(), "\"level\":0") != null);
    try testing.expectEqual(0, levelOf("\x1b[1mtrace:\x1b[0m x"));
    try testing.expectEqual(1, levelOf("\x1b[35;1mevaluation warning:\x1b[0m x"));
    try testing.expectEqual(3, levelOf("\x1b[1mwarn\x1b[0m"));
}

test "a mismatch reason keeps both hashes" {
    const a = testing.allocator;
    const raw = "status 5: hash mismatch in fixed-output derivation '/nix/store/x.drv':\n  specified: sha256-AAAA=\n     got:    sha256-BBBB=";
    const l1 = try reasonLine(a, raw);
    defer a.free(l1);
    try testing.expectEqualStrings("status 5: hash mismatch in fixed-output derivation '/nix/store/x.drv': specified: sha256-AAAA=, got: sha256-BBBB=", l1);
    const l2 = try reasonLine(a, "status 3: Cannot build 'x'.\nmore");
    defer a.free(l2);
    try testing.expectEqualStrings("status 3: Cannot build 'x'.", l2);
}

test "a hash mismatch names the hash it got" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const reason = "status 5: hash mismatch in fixed-output derivation '/nix/store/x.drv':\n  specified: sha256-AAAA=\n     got:    sha256-BBBB=";
    const r = try buildReport(arena.allocator(), "/a.nix:4:3", reason, 102);
    try testing.expectEqualStrings("hash-mismatch", r.code);
    try testing.expectEqualStrings("set the expected hash to 'sha256-BBBB='", r.hint.?);
    try testing.expect(std.mem.startsWith(u8, r.raw, "hash mismatch in fixed-output derivation"));
    try testing.expectEqualStrings("build-failed", (try buildReport(arena.allocator(), null, "status 3: Cannot build", 100)).code);
}
