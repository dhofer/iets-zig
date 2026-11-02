//! One nix-eval-jobs output line: a job or an error. Keys are byte-sorted
//! like nlohmann's `std::map`; values iets never inspects stay raw JSON so
//! a line survives a round trip through a worker pipe unchanged.
//!
//! A line owns its strings, allocated in the `gpa` its `deinit` gets: lines
//! travel between threads and outlive the request that made them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Diag = @import("../diag.zig").Diag;
const text = @import("../syntax/text.zig");
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;

pub const Error = error{ Protocol, Store, OutOfMemory };

/// A key and its raw JSON value.
pub const Field = struct { key: []const u8, value: []const u8 };

/// An output and its path; `null` for a CA output.
pub const Output = struct { name: []const u8, path: ?StorePath };

pub const Job = struct {
    attr: []const u8,
    attr_path: []const []const u8,
    drv_path: StorePath,
    /// Sorted by name.
    outputs: std.ArrayList(Output) = .empty,
    /// Constituent `.drv`s: the string context of `constituents`, then the
    /// named ones once `--constituents` resolved them.
    constituents: std.ArrayList(StorePath) = .empty,
    /// `null` once `--constituents` erased the key from a resolved aggregate.
    named_constituents: ?[]const []const u8 = null,
    glob_constituents: bool = false,
    /// Every other key, as raw JSON, sorted by key.
    extra: std.ArrayList(Field) = .empty,

    pub fn deinit(j: *Job, gpa: Allocator) void {
        gpa.free(j.attr);
        freeStrs(gpa, j.attr_path);
        for (j.outputs.items) |o| gpa.free(o.name);
        j.outputs.deinit(gpa);
        j.constituents.deinit(gpa);
        if (j.named_constituents) |n| freeStrs(gpa, n);
        for (j.extra.items) |f| freeField(gpa, f);
        j.extra.deinit(gpa);
        j.* = undefined;
    }

    pub fn setNamedConstituents(j: *Job, gpa: Allocator, named: ?[]const []const u8) void {
        if (j.named_constituents) |n| freeStrs(gpa, n);
        j.named_constituents = named;
    }

    /// Sets `key` to `value`, raw JSON the job takes over (freed on failure).
    pub fn putExtra(j: *Job, gpa: Allocator, key: []const u8, value: []u8) Allocator.Error!void {
        errdefer gpa.free(value);
        const at = find(Field, "key", j.extra.items, key);
        if (at.found) {
            gpa.free(j.extra.items[at.i].value);
            j.extra.items[at.i].value = value;
            return;
        }
        const k = try gpa.dupe(u8, key);
        errdefer gpa.free(k);
        try j.extra.insert(gpa, at.i, .{ .key = k, .value = value });
    }

    pub fn getExtra(j: *const Job, key: []const u8) ?[]const u8 {
        const at = find(Field, "key", j.extra.items, key);
        return if (at.found) j.extra.items[at.i].value else null;
    }

    /// Sets output `name`'s path.
    pub fn putOutput(j: *Job, gpa: Allocator, name: []const u8, path: ?StorePath) Allocator.Error!void {
        const at = find(Output, "name", j.outputs.items, name);
        if (at.found) {
            j.outputs.items[at.i].path = path;
            return;
        }
        const n = try gpa.dupe(u8, name);
        errdefer gpa.free(n);
        try j.outputs.insert(gpa, at.i, .{ .name = n, .path = path });
    }

    /// Compact JSON with keys in byte order, as nlohmann `dump()` prints it.
    pub fn render(j: *const Job, w: *Writer) Writer.Error!void {
        // The fixed keys in byte order; the extra keys merge in around them.
        const fixed = [_][]const u8{ "attr", "attrPath", "constituents", "drvPath", "globConstituents", "namedConstituents", "outputs" };
        try w.writeByte('{');
        var first = true;
        var e: usize = 0;
        for (fixed, 0..) |k, fi| {
            if (fi == 5 and j.named_constituents == null) continue;
            // a sort that keeps equal keys in place puts the fixed key first
            while (e < j.extra.items.len and std.mem.lessThan(u8, j.extra.items[e].key, k)) : (e += 1)
                try writeField(w, &first, j.extra.items[e].key, j.extra.items[e].value);
            try writeKey(w, &first, k);
            switch (fi) {
                0 => try writeStr(w, j.attr),
                1 => try writeStrList(w, j.attr_path),
                2 => try writePathList(w, j.constituents.items),
                3 => try writePath(w, &j.drv_path),
                4 => try w.writeAll(if (j.glob_constituents) "true" else "false"),
                5 => try writeStrList(w, j.named_constituents.?),
                6 => {
                    try w.writeByte('{');
                    for (j.outputs.items, 0..) |o, i| {
                        if (i > 0) try w.writeByte(',');
                        try writeStr(w, o.name);
                        try w.writeByte(':');
                        if (o.path) |*p| try writePath(w, p) else try w.writeAll("null");
                    }
                    try w.writeByte('}');
                },
                else => unreachable,
            }
        }
        for (j.extra.items[e..]) |f| try writeField(w, &first, f.key, f.value);
        try w.writeByte('}');
    }
};

pub const ErrorLine = struct {
    attr: []const u8,
    attr_path: []const []const u8,
    /// The `error` field.
    message: []const u8,
    fatal: bool = false,
    /// `stats` as raw JSON, when a worker measured the request.
    stats: ?[]const u8 = null,

    pub fn deinit(e: *ErrorLine, gpa: Allocator) void {
        gpa.free(e.attr);
        freeStrs(gpa, e.attr_path);
        gpa.free(e.message);
        if (e.stats) |s| gpa.free(s);
        e.* = undefined;
    }

    pub fn render(e: *const ErrorLine, w: *Writer) Writer.Error!void {
        var first = true;
        try w.writeByte('{');
        try writeKey(w, &first, "attr");
        try writeStr(w, e.attr);
        try writeKey(w, &first, "attrPath");
        try writeStrList(w, e.attr_path);
        try writeKey(w, &first, "error");
        try writeStr(w, e.message);
        try writeField(w, &first, "fatal", if (e.fatal) "true" else "false");
        if (e.stats) |s| try writeField(w, &first, "stats", s);
        try w.writeByte('}');
    }
};

/// worker.cc:processJobRequest's `stats`: the request's wall time and the
/// bytes it allocated, arena bytes here where nix counts Boehm's.
pub fn statsJson(gpa: Allocator, wall_ms: u64, alloc_bytes: u64) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"allocBytes\":{d},\"wallMs\":{d}}}", .{ alloc_bytes, wall_ms });
}

pub const Line = union(enum) {
    job: Job,
    err: ErrorLine,

    pub fn deinit(l: *Line, gpa: Allocator) void {
        switch (l.*) {
            .job => |*j| j.deinit(gpa),
            .err => |*e| e.deinit(gpa),
        }
    }

    pub fn render(l: *const Line, w: *Writer) Writer.Error!void {
        return switch (l.*) {
            .job => |*j| j.render(w),
            .err => |*e| e.render(w),
        };
    }

    pub fn renderAlloc(l: *const Line, gpa: Allocator) Allocator.Error![]u8 {
        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();
        l.render(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    pub fn attr(l: *const Line) []const u8 {
        return switch (l.*) {
            .job => |*j| j.attr,
            .err => |*e| e.attr,
        };
    }

    /// Parses a line a worker printed. A line with `drvPath` is a job, one
    /// with `error` and no `drvPath` is an error.
    pub fn parse(gpa: Allocator, bytes: []const u8, d: *Diag) Error!Line {
        var fields = try splitObject(gpa, bytes, d);
        defer {
            for (fields.items) |f| gpa.free(f.key);
            fields.deinit(gpa);
        }
        // a map, as Rust iets reads one: the last of a repeated key wins
        std.mem.sort(Field, fields.items, {}, fieldLess);
        var n: usize = 0;
        for (fields.items, 0..) |f, i| {
            if (i + 1 < fields.items.len and std.mem.eql(u8, f.key, fields.items[i + 1].key)) {
                gpa.free(f.key);
                continue;
            }
            fields.items[n] = f;
            n += 1;
        }
        fields.items.len = n;
        var m: Map = .{ .fields = fields.items };

        const attr_ = try m.str(gpa, "attr", d);
        errdefer gpa.free(attr_);
        const attr_path = try m.strs(gpa, "attrPath", d);
        errdefer freeStrs(gpa, attr_path);
        if (m.get("drvPath") == null) {
            const message = try m.str(gpa, "error", d);
            errdefer gpa.free(message);
            const fatal = if (m.take("fatal")) |v| std.mem.eql(u8, v, "true") else false;
            const stats = if (m.take("stats")) |v| try gpa.dupe(u8, v) else null;
            return .{ .err = .{ .attr = attr_, .attr_path = attr_path, .message = message, .fatal = fatal, .stats = stats } };
        }
        var job: Job = .{ .attr = attr_, .attr_path = attr_path, .drv_path = undefined };
        errdefer {
            for (job.outputs.items) |o| gpa.free(o.name);
            job.outputs.deinit(gpa);
            job.constituents.deinit(gpa);
            if (job.named_constituents) |nc| freeStrs(gpa, nc);
            for (job.extra.items) |f| freeField(gpa, f);
            job.extra.deinit(gpa);
        }
        {
            const s = try m.str(gpa, "drvPath", d);
            defer gpa.free(s);
            job.drv_path = try parsePath(s, d);
        }
        const raw_outputs = m.take("outputs") orelse return d.fail(error.Protocol, "job without 'outputs'", .{});
        var outs = splitObject(gpa, raw_outputs, d) catch |e| return prefixed(d, e, "outputs");
        defer {
            for (outs.items) |f| gpa.free(f.key);
            outs.deinit(gpa);
        }
        for (outs.items) |o| {
            var p: ?StorePath = null;
            if (!std.mem.eql(u8, o.value, "null")) {
                const s = decodeString(gpa, o.value, d) catch |e| return prefixed(d, e, "outputs");
                defer gpa.free(s);
                p = try parsePath(s, d);
            }
            try job.putOutput(gpa, o.key, p);
        }
        {
            const cs = try m.strs(gpa, "constituents", d);
            defer freeStrs(gpa, cs);
            try job.constituents.ensureTotalCapacityPrecise(gpa, cs.len);
            for (cs) |s| job.constituents.appendAssumeCapacity(try parsePath(s, d));
        }
        if (m.take("namedConstituents")) |raw|
            job.named_constituents = decodeStrList(gpa, raw, d) catch |e| return prefixed(d, e, "namedConstituents");
        job.glob_constituents = if (m.take("globConstituents")) |v| std.mem.eql(u8, v, "true") else false;
        for (m.fields) |f| {
            if (f.value.len == 0) continue; // taken
            try job.extra.ensureUnusedCapacity(gpa, 1);
            const k = try gpa.dupe(u8, f.key);
            errdefer gpa.free(k);
            job.extra.appendAssumeCapacity(.{ .key = k, .value = try gpa.dupe(u8, f.value) });
        }
        return .{ .job = job };
    }
};

/// The fields of a parsed line, sorted and unique; a taken field's value is
/// emptied (no JSON value is empty).
const Map = struct {
    fields: []Field,

    fn get(m: *const Map, k: []const u8) ?[]const u8 {
        const at = find(Field, "key", m.fields, k);
        if (!at.found or m.fields[at.i].value.len == 0) return null;
        return m.fields[at.i].value;
    }

    fn take(m: *Map, k: []const u8) ?[]const u8 {
        const at = find(Field, "key", m.fields, k);
        if (!at.found or m.fields[at.i].value.len == 0) return null;
        defer m.fields[at.i].value = "";
        return m.fields[at.i].value;
    }

    fn str(m: *Map, gpa: Allocator, k: []const u8, d: *Diag) Error![]u8 {
        const raw = m.take(k) orelse return d.fail(error.Protocol, "line without '{s}'", .{k});
        return decodeString(gpa, raw, d) catch |e| prefixed(d, e, k);
    }

    fn strs(m: *Map, gpa: Allocator, k: []const u8, d: *Diag) Error![]const []const u8 {
        const raw = m.take(k) orelse return d.fail(error.Protocol, "line without '{s}'", .{k});
        return decodeStrList(gpa, raw, d) catch |e| prefixed(d, e, k);
    }
};

fn prefixed(d: *Diag, e: Error, k: []const u8) Error {
    if (e == error.OutOfMemory) return e;
    const old = d.msg orelse return e;
    d.msg = std.fmt.allocPrint(d.gpa, "'{s}': {s}", .{ k, old }) catch null;
    d.gpa.free(old);
    return e;
}

fn parsePath(s: []const u8, d: *Diag) Error!StorePath {
    return StorePath.parse(s, d) catch error.Store;
}

fn fieldLess(_: void, a: Field, b: Field) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn find(comptime T: type, comptime key: []const u8, items: []const T, k: []const u8) struct { i: usize, found: bool } {
    var lo: usize = 0;
    var hi: usize = items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, @field(items[mid], key), k)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return .{ .i = mid, .found = true },
        }
    }
    return .{ .i = lo, .found = false };
}

fn freeStrs(gpa: Allocator, items: []const []const u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

fn freeField(gpa: Allocator, f: Field) void {
    gpa.free(f.key);
    gpa.free(f.value);
}

// Writing.

fn writeKey(w: *Writer, first: *bool, k: []const u8) Writer.Error!void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try writeStr(w, k);
    try w.writeByte(':');
}

fn writeField(w: *Writer, first: *bool, k: []const u8, v: []const u8) Writer.Error!void {
    try writeKey(w, first, k);
    try w.writeAll(v);
}

/// A JSON string as Rust iets writes it.
pub fn writeStr(w: *Writer, s: []const u8) Writer.Error!void {
    return text.writeJsonString(w, s);
}

pub fn writeStrList(w: *Writer, items: []const []const u8) Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |s, i| {
        if (i > 0) try w.writeByte(',');
        try writeStr(w, s);
    }
    try w.writeByte(']');
}

/// The full path as a JSON string; store paths never need escapes.
pub fn writePath(w: *Writer, p: *const StorePath) Writer.Error!void {
    try w.writeByte('"');
    try p.format(w);
    try w.writeByte('"');
}

pub fn writePathList(w: *Writer, items: []const StorePath) Writer.Error!void {
    try w.writeByte('[');
    for (items, 0..) |*p, i| {
        if (i > 0) try w.writeByte(',');
        try writePath(w, p);
    }
    try w.writeByte(']');
}

/// A JSON string the caller owns.
pub fn jsonStr(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    return alloc(gpa, writeStr, .{s});
}

/// A JSON array of strings, owned by the caller.
pub fn jsonStrList(gpa: Allocator, items: []const []const u8) Allocator.Error![]u8 {
    return alloc(gpa, writeStrList, .{items});
}

/// A JSON array of store paths, owned by the caller.
pub fn jsonPathList(gpa: Allocator, items: []const StorePath) Allocator.Error![]u8 {
    return alloc(gpa, writePathList, .{items});
}

fn alloc(gpa: Allocator, comptime f: anytype, args: anytype) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    @call(.auto, f, .{&aw.writer} ++ args) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// Reading.

fn skipWs(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and (s[j] == ' ' or s[j] == '\t' or s[j] == '\n' or s[j] == '\r')) j += 1;
    return j;
}

/// `i` is at the opening quote; returns the index after the closing one.
fn scanString(s: []const u8, i: usize, d: *Diag) Error!usize {
    var j = i + 1;
    while (j < s.len) {
        switch (s[j]) {
            '\\' => j += 2,
            '"' => return j + 1,
            else => j += 1,
        }
    }
    return d.fail(error.Protocol, "unterminated string", .{});
}

fn scanValue(s: []const u8, i: usize, d: *Diag) Error!usize {
    if (i >= s.len) return d.fail(error.Protocol, "missing value", .{});
    switch (s[i]) {
        '"' => return scanString(s, i, d),
        '{', '[' => {
            var depth: usize = 0;
            var j = i;
            while (j < s.len) {
                switch (s[j]) {
                    '"' => j = try scanString(s, j, d),
                    '{', '[' => {
                        depth += 1;
                        j += 1;
                    },
                    '}', ']' => {
                        depth -= 1;
                        j += 1;
                        if (depth == 0) return j;
                    },
                    else => j += 1,
                }
            }
            return d.fail(error.Protocol, "unterminated object", .{});
        },
        else => {
            var j = i;
            while (j < s.len) : (j += 1) switch (s[j]) {
                ',', '}', ']', ' ', '\n', '\t', '\r' => break,
                else => {},
            };
            return j;
        },
    }
}

/// The top-level keys of a JSON object, decoded into `gpa`, and the raw
/// text of their values, slices of `s`.
pub fn splitObject(gpa: Allocator, s: []const u8, d: *Diag) Error!std.ArrayList(Field) {
    var out: std.ArrayList(Field) = .empty;
    errdefer {
        for (out.items) |f| gpa.free(f.key);
        out.deinit(gpa);
    }
    var i = skipWs(s, 0);
    if (i >= s.len or s[i] != '{') return d.fail(error.Protocol, "expected '{{'", .{});
    i = skipWs(s, i + 1);
    if (i < s.len and s[i] == '}') return out;
    while (true) {
        if (i >= s.len or s[i] != '"') return d.fail(error.Protocol, "expected a key", .{});
        const kend = try scanString(s, i, d);
        const key = try decodeString(gpa, s[i..kend], d);
        out.append(gpa, .{ .key = key, .value = "" }) catch |e| {
            gpa.free(key);
            return e;
        };
        i = skipWs(s, kend);
        if (i >= s.len or s[i] != ':') return d.fail(error.Protocol, "expected ':'", .{});
        i = skipWs(s, i + 1);
        const vend = try scanValue(s, i, d);
        out.items[out.items.len - 1].value = s[i..vend];
        i = skipWs(s, vend);
        if (i < s.len and s[i] == ',') {
            i = skipWs(s, i + 1);
        } else if (i < s.len and s[i] == '}') {
            return out;
        } else return d.fail(error.Protocol, "expected ',' or '}}'", .{});
    }
}

/// A JSON string literal (quotes included) to its UTF-8 text, as
/// Rust iets reads it.
pub fn decodeString(gpa: Allocator, raw: []const u8, d: *Diag) Error![]u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"')
        return d.fail(error.Protocol, "expected a string", .{});
    const body = raw[1 .. raw.len - 1];
    for (body) |c| if (c < 0x20) return d.fail(error.Protocol, "control character in string", .{});
    if (!std.unicode.utf8ValidateSlice(body)) return d.fail(error.Protocol, "invalid unicode in string", .{});
    if (std.mem.indexOfScalar(u8, body, '\\') == null) return gpa.dupe(u8, body);
    var out: std.ArrayList(u8) = try .initCapacity(gpa, body.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c != '\\') {
            out.appendAssumeCapacity(c);
            i += 1;
            continue;
        }
        if (i + 1 >= body.len) return d.fail(error.Protocol, "unterminated string", .{});
        const e = body[i + 1];
        i += 2;
        const lit: u8 = switch (e) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => {
                var cp: u21 = try hex4(body, i, d);
                i += 4;
                if (cp >= 0xd800 and cp < 0xdc00) {
                    if (i + 6 > body.len or body[i] != '\\' or body[i + 1] != 'u')
                        return d.fail(error.Protocol, "lone leading surrogate in hex escape", .{});
                    const lo = try hex4(body, i + 2, d);
                    if (lo < 0xdc00 or lo >= 0xe000) return d.fail(error.Protocol, "lone leading surrogate in hex escape", .{});
                    i += 6;
                    cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                } else if (cp >= 0xdc00 and cp < 0xe000) {
                    return d.fail(error.Protocol, "unexpected end of hex escape", .{});
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
                // an escape is at least as long as its encoding
                out.appendSliceAssumeCapacity(buf[0..n]);
                continue;
            },
            else => return d.fail(error.Protocol, "invalid escape", .{}),
        };
        out.appendAssumeCapacity(lit);
    }
    return out.toOwnedSlice(gpa);
}

fn hex4(s: []const u8, i: usize, d: *Diag) Error!u21 {
    if (i + 4 > s.len) return d.fail(error.Protocol, "unexpected end of hex escape", .{});
    return std.fmt.parseInt(u16, s[i..][0..4], 16) catch d.fail(error.Protocol, "invalid escape", .{});
}

/// A JSON array of strings to its items, as Rust iets reads one.
pub fn decodeStrList(gpa: Allocator, raw: []const u8, d: *Diag) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    var i = skipWs(raw, 0);
    if (i >= raw.len or raw[i] != '[') return d.fail(error.Protocol, "expected an array", .{});
    i = skipWs(raw, i + 1);
    if (i < raw.len and raw[i] == ']') {
        if (skipWs(raw, i + 1) != raw.len) return d.fail(error.Protocol, "trailing characters", .{});
        return out.toOwnedSlice(gpa);
    }
    while (true) {
        if (i >= raw.len or raw[i] != '"') return d.fail(error.Protocol, "expected a string", .{});
        const end = try scanString(raw, i, d);
        try out.ensureUnusedCapacity(gpa, 1);
        out.appendAssumeCapacity(try decodeString(gpa, raw[i..end], d));
        i = skipWs(raw, end);
        if (i < raw.len and raw[i] == ',') {
            i = skipWs(raw, i + 1);
        } else if (i < raw.len and raw[i] == ']') {
            if (skipWs(raw, i + 1) != raw.len) return d.fail(error.Protocol, "trailing characters", .{});
            return out.toOwnedSlice(gpa);
        } else return d.fail(error.Protocol, "expected ',' or ']'", .{});
    }
}

const testing = std.testing;

fn roundTrip(line: []const u8) !void {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var parsed = try Line.parse(testing.allocator, line, &d);
    defer parsed.deinit(testing.allocator);
    const out = try parsed.renderAlloc(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(line, out);
}

test "split and round trip" {
    const gpa = testing.allocator;
    const line =
        \\{"attr":"a.b","attrPath":["a","b"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-x.drv","globConstituents":false,"meta":{"x":[1,"}"]},"name":"x","namedConstituents":["n"],"outputs":{"out":"/nix/store/00000000000000000000000000000000-x"},"storeDir":"/nix/store","system":"x86_64-linux"}
    ;
    var d: Diag = .init(gpa);
    defer d.deinit();
    var fields = try splitObject(gpa, line, &d);
    defer {
        for (fields.items) |f| gpa.free(f.key);
        fields.deinit(gpa);
    }
    try testing.expectEqual(11, fields.items.len);
    try testing.expectEqualStrings("meta", fields.items[5].key);
    try testing.expectEqualStrings(
        \\{"x":[1,"}"]}
    , fields.items[5].value);
    try roundTrip(line);

    var parsed = try Line.parse(gpa, line, &d);
    defer parsed.deinit(gpa);
    const j = &parsed.job;
    try testing.expectEqual(1, j.named_constituents.?.len);
    try testing.expectEqualStrings("n", j.named_constituents.?[0]);
    j.setNamedConstituents(gpa, null);
    const out = try parsed.renderAlloc(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "namedConstituents") == null);
}

test "error line round trip" {
    const line =
        \\{"attr":"d","attrPath":["d"],"error":"error:\n  x","fatal":false}
    ;
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var parsed = try Line.parse(testing.allocator, line, &d);
    defer parsed.deinit(testing.allocator);
    try testing.expect(parsed == .err);
    try testing.expectEqualStrings("error:\n  x", parsed.err.message);
    try roundTrip(line);
}

test "stats survive the collector" {
    const gpa = testing.allocator;
    const stats = try statsJson(gpa, 412, 7632);
    defer gpa.free(stats);
    try testing.expectEqualStrings(
        \\{"allocBytes":7632,"wallMs":412}
    , stats);
    const err = try std.fmt.allocPrint(gpa,
        \\{{"attr":"d","attrPath":["d"],"error":"x","fatal":false,"stats":{s}}}
    , .{stats});
    defer gpa.free(err);
    try roundTrip(err);
    const job = try std.fmt.allocPrint(gpa,
        \\{{"attr":"a","attrPath":["a"],"constituents":[],"drvPath":"/nix/store/00000000000000000000000000000000-x.drv","globConstituents":false,"name":"x","outputs":{{}},"stats":{s},"system":"x86_64-linux"}}
    , .{stats});
    defer gpa.free(job);
    try roundTrip(job);
}

test "extra keys before the fixed ones, escapes and CA outputs" {
    // `aaa` sorts before `attr`, `cacheStatus` between `attrPath` and
    // `constituents`; escapes come back as Rust iets writes them
    const in =
        \\{"aaa":1,"attr":"\u0001\"\\\u00e9\ud83d\ude00","attrPath":[],"cacheStatus":"local","constituents":["/nix/store/00000000000000000000000000000000-c.drv"],"drvPath":"/nix/store/00000000000000000000000000000000-x.drv","globConstituents":true,"outputs":{"dev":null,"out":"/nix/store/00000000000000000000000000000000-x"},"zzz":[]}
    ;
    const want =
        \\{"aaa":1,"attr":"\u0001\"\\é😀","attrPath":[],"cacheStatus":"local","constituents":["/nix/store/00000000000000000000000000000000-c.drv"],"drvPath":"/nix/store/00000000000000000000000000000000-x.drv","globConstituents":true,"outputs":{"dev":null,"out":"/nix/store/00000000000000000000000000000000-x"},"zzz":[]}
    ;
    {
        var d: Diag = .init(testing.allocator);
        defer d.deinit();
        var parsed = try Line.parse(testing.allocator, in, &d);
        defer parsed.deinit(testing.allocator);
        const out = try parsed.renderAlloc(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings(want, out);
    }
    try roundTrip(want);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Protocol, Line.parse(testing.allocator, "{\"attrPath\":[]}", &d));
    try testing.expectEqualStrings("line without 'attr'", d.message());
    try testing.expectError(error.Protocol, Line.parse(testing.allocator, "{\"attr\":1,\"attrPath\":[]}", &d));
    try testing.expectError(error.Store, Line.parse(testing.allocator,
        \\{"attr":"a","attrPath":[],"constituents":[],"drvPath":"/tmp/x","outputs":{}}
    , &d));
}

test "a decoded escape" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const s = try decodeString(testing.allocator, "\"a\\u00e9\\ud83d\\ude00\\n\"", &d);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("a\u{e9}\u{1f600}\n", s);
    try testing.expectError(error.Protocol, decodeString(testing.allocator, "\"\\ud83d\"", &d));
}
