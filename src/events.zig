//! Instrumentation: one JSON object per line, naming what an evaluation
//! did. The `IETS_STATS` counters say how much;
//! these say which path, from where, and how big. `IETS_EVENTS` names the
//! groups a run watches and `IETS_EVENTS_TO` where they go; a host calls
//! `Events.watch` and `Events.writeTo` instead (docs/reference/events.md).
//!
//! The stream is for a program to read: every record has an `event` name
//! and keeps the fields it was published with. Adding a field is not a
//! change a reader must follow.

const std = @import("std");
const text = @import("syntax/text.zig");
const linux = std.os.linux;
const sys = @import("sys.zig");
const log = @import("log.zig");
const errors = @import("errors.zig");

/// A part of the evaluator, and the unit a run turns on. A group costs what
/// its rate class costs, so `all` takes the cold ones and a warm one is
/// named or left out (docs/reference/events.md). The order is the one
/// `iets help events` lists them in.
pub const Group = enum(u5) {
    syntax,
    ir,
    import,
    store,
    drv,
    fetch,
    flake,
    cache,
    io,
    build,
    lint,
    @"error",

    pub fn name(g: Group) []const u8 {
        return @tagName(g);
    }

    /// A group whose rate makes it worth naming: `all` leaves it out.
    pub fn warm(g: Group) bool {
        return g == .drv or g == .io;
    }

    fn bit(g: Group) u32 {
        return @as(u32, 1) << @backingInt(g);
    }

    /// The mask `names` asks for: a comma-separated list, or `all` for every
    /// cold group. A name that is not a group comes back as `bad`, because
    /// a mistyped group would otherwise watch nothing in silence.
    pub fn mask(names: []const u8) union(enum) { ok: u32, bad: []const u8 } {
        var m: u32 = 0;
        var it = std.mem.splitScalar(u8, names, ',');
        while (it.next()) |raw| {
            const n = std.mem.trim(u8, raw, " \t\n\r");
            if (n.len == 0) continue;
            if (std.mem.eql(u8, n, "all")) {
                for (std.enums.values(Group)) |g| {
                    if (!g.warm()) m |= g.bit();
                }
                continue;
            }
            const g = std.meta.stringToEnum(Group, n) orelse return .{ .bad = n };
            m |= g.bit();
        }
        return .{ .ok = m };
    }

    /// `'NAME' is not an event group (all, syntax, ...)`.
    pub fn badName(w: *std.Io.Writer, n: []const u8) !void {
        try w.print("'{s}' is not an event group (all", .{n});
        for (std.enums.values(Group)) |g| try w.print(", {s}", .{g.name()});
        try w.writeByte(')');
    }
};

/// Where one session's events go, and which groups it wants. No group is
/// the normal case: nothing asked for them, so no hook builds a record.
pub const Events = struct {
    groups: std.atomic.Value(u32) = .init(0),
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The sink's file descriptor; -1 for none. Each record is one write.
    fd: linux.fd_t = -1,
    owned: bool = false,
    lock: std.Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Events {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(e: *Events) void {
        if (e.owned) _ = linux.close(e.fd);
    }

    /// Watches the groups in `m` (`Group.mask` parses the names).
    pub fn watch(e: *Events, m: u32) void {
        e.groups.store(m, .monotonic);
    }

    /// Sends every event to `fd`, which stays the caller's.
    pub fn writeTo(e: *Events, fd: linux.fd_t) void {
        e.fd = fd;
    }

    /// Watches the `mask` of `IETS_EVENTS`, where `IETS_EVENTS_TO` says. A
    /// path that does not open is reported once and the stream stays off,
    /// as a `json-log-path` that does not open is.
    pub fn open(e: *Events, mask: u32, to: ?[]const u8, l: *log.Log) void {
        if (mask == 0) return;
        e.watch(mask);
        const path = to orelse "-";
        if (std.mem.eql(u8, path, "-")) return e.writeTo(2);
        switch (sys.fs.openSink(path)) {
            .fd => |fd| {
                e.fd = fd;
                e.owned = true;
            },
            .err => |er| {
                var buf: [std.fs.max_path_bytes + 128]u8 = undefined;
                l.errln(std.fmt.bufPrint(&buf, "error (ignored): opening events file \"{s}\": {s}", .{ path, errors.errnoText(er) }) catch return);
            },
        }
    }

    /// Whether `group` is watched. A site that must gather something before
    /// it can fill a record asks this first.
    pub fn on(e: *const Events, group: Group) bool {
        return e.groups.load(.monotonic) & group.bit() != 0;
    }

    /// A builder for one `{"event": NAME, …}` line, and null when the group
    /// is not watched: a call site asks first and builds nothing for a run
    /// that does not want it. `Rec.end` writes the line.
    pub fn rec(e: *Events, group: Group, event: []const u8) ?Rec {
        if (!e.on(group) or e.fd < 0) return null;
        var r: Rec = .{ .events = e };
        r.raw("{\"event\":");
        r.str(event);
        return r;
    }
};

/// One record under construction. Each field appends to a line the record
/// owns, on the caller's stack until it outgrows it; the line reaches the
/// sink in one write at `end`, because a write per fragment cost 6% of a
/// nixpkgs evaluation's instructions. The record carries the line, not a
/// thread-local: fibers migrate between threads.
pub const Rec = struct {
    events: *Events,
    small: [1024]u8 = undefined,
    len: usize = 0,
    big: std.ArrayList(u8) = .empty,
    /// An allocation failed: the record is dropped at `end`.
    lost: bool = false,

    fn bytes(r: *Rec) []const u8 {
        return if (r.big.items.len > 0) r.big.items else r.small[0..r.len];
    }

    /// Appends `b` as it is.
    pub fn raw(r: *Rec, b: []const u8) void {
        if (r.big.items.len == 0 and r.len + b.len <= r.small.len) {
            @memcpy(r.small[r.len..][0..b.len], b);
            r.len += b.len;
            return;
        }
        if (r.big.items.len == 0) r.big.appendSlice(r.events.gpa, r.small[0..r.len]) catch {
            r.lost = true;
            return;
        };
        r.big.appendSlice(r.events.gpa, b) catch {
            r.lost = true;
        };
    }

    /// `s` as a JSON string. Invalid UTF-8 is replaced, because a path is
    /// bytes and a record is never worth failing a run over.
    pub fn str(r: *Rec, s: []const u8) void {
        r.raw("\"");
        var run: usize = 0;
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];
            if (c >= 0x20 and c != '"' and c != '\\' and c < 0x80) {
                i += 1;
                continue;
            }
            if (c >= 0x80) {
                const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
                if (n > 0 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + n])) {
                    i += n;
                    continue;
                }
            }
            r.raw(s[run..i]);
            var buf: [8]u8 = undefined;
            r.raw(switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                0x08 => "\\b",
                0x0c => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                else => if (c < 0x20) std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable else "\u{fffd}",
            });
            i += if (c < 0x80) 1 else text.invalidLen(s, i);
            run = i;
        }
        r.raw(s[run..]);
        r.raw("\"");
    }

    pub fn int(r: *Rec, n: u64) void {
        var buf: [20]u8 = undefined;
        r.raw(std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable);
    }

    fn key(r: *Rec, k: []const u8) void {
        r.raw(",");
        r.str(k);
        r.raw(":");
    }

    /// One field. Chains, so a call site reads as the record it writes.
    pub fn set(r: *Rec, k: []const u8, v: anytype) *Rec {
        r.key(k);
        switch (@typeInfo(@TypeOf(v))) {
            .bool => r.raw(if (v) "true" else "false"),
            .int, .comptime_int => r.int(@intCast(v)),
            else => r.str(v),
        }
        return r;
    }

    /// A field whose string a caller writes in pieces: `start` before, then
    /// `raw`, then `quote`. A value with nothing to escape — nearly every
    /// path and name — copies nothing and inserts two bytes; one that needs
    /// escaping pays a copy.
    pub fn start(r: *Rec, k: []const u8) usize {
        r.key(k);
        return r.bytes().len;
    }

    pub fn quote(r: *Rec, from: usize) void {
        const b = r.bytes();
        const plain = for (b[from..]) |c| {
            if (c < 0x20 or c == '"' or c == '\\') break false;
        } else std.unicode.utf8ValidateSlice(b[from..]);
        if (plain) {
            // one byte more, then the value moves up over it
            r.raw("\"");
            if (r.lost) return;
            const m = if (r.big.items.len > 0) r.big.items else r.small[0..r.len];
            std.mem.copyBackwards(u8, m[from + 1 ..], m[from .. m.len - 1]);
            m[from] = '"';
            r.raw("\"");
            return;
        }
        const tail = r.events.gpa.dupe(u8, b[from..]) catch {
            r.lost = true;
            return;
        };
        defer r.events.gpa.free(tail);
        if (r.big.items.len > 0) r.big.shrinkRetainingCapacity(from) else r.len = from;
        r.str(tail);
    }

    /// Writes the line and frees what the record took.
    pub fn end(r: *Rec) void {
        defer r.big.deinit(r.events.gpa);
        if (r.lost) return;
        r.raw("}\n");
        if (r.lost) return;
        const e = r.events;
        e.lock.lockUncancelable(e.io);
        defer e.lock.unlock(e.io);
        sys.fs.writeAll(e.fd, r.bytes()) catch {};
    }
};

const testing = std.testing;

test "a group mask takes names and all" {
    try testing.expectEqual(Group.store.bit() | Group.fetch.bit(), Group.mask("store, fetch").ok);
    const all = Group.mask("all").ok;
    try testing.expect(all & Group.store.bit() != 0 and all & Group.drv.bit() == 0 and all & Group.io.bit() == 0);
    try testing.expectEqual(all | Group.io.bit(), Group.mask("all,io").ok);
    try testing.expectEqual(0, Group.mask("").ok);
    try testing.expectEqualStrings("stor", Group.mask("store,stor").bad);
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try Group.badName(&w, "stor");
    try testing.expectEqualStrings("'stor' is not an event group (all, syntax, ir, import, store, drv, fetch, flake, cache, io, build, lint, error)", w.buffered());
}

test "a record is one line in one write" {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe(&fds)));
    defer _ = linux.close(fds[0]);
    var e: Events = .init(testing.allocator, testing.io);
    e.writeTo(fds[1]);
    try testing.expect(e.rec(.store, "store-add") == null);
    e.watch(Group.mask("store").ok);
    var r = e.rec(.store, "store-add").?;
    _ = r.set("path", "/nix/store/x-a\"b").set("size", 2).set("ok", true);
    const at = r.start("at");
    r.raw("«string»:1:4");
    r.quote(at);
    const long: [3000]u8 = @splat('x');
    _ = r.set("long", &long);
    const esc = r.start("esc");
    r.raw("a\"b");
    r.quote(esc);
    const big = r.start("big");
    r.raw("y");
    r.quote(big);
    r.end();
    _ = linux.close(fds[1]);
    var buf: [8192]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const rc = linux.read(fds[0], buf[n..].ptr, buf.len - n);
        if (rc == 0 or linux.errno(rc) != .SUCCESS) break;
        n += rc;
    }
    const want = "{\"event\":\"store-add\",\"path\":\"/nix/store/x-a\\\"b\",\"size\":2,\"ok\":true,\"at\":\"«string»:1:4\",\"long\":\"" ++ long ++ "\",\"esc\":\"a\\\"b\",\"big\":\"y\"}\n";
    try testing.expectEqualStrings(want, buf[0..n]);
}
