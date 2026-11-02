//! The messages of nix-grpc-store's `nix_remote.proto` (package `nix.remote`) and
//! a comptime protobuf codec for them.
//!
//! A message is a struct whose `tags` declaration numbers its fields. Field
//! types map to protobuf as: `[]const u8` is `string`/`bytes`, `bool`, `u32`
//! and `u64` are varints, `?bool` is a proto3 `optional bool`, `?M` a
//! singular message, `[]const []const u8` and `[]const M` repeated fields,
//! and `?U` with `U` a tagged union (its own `tags`) a `oneof`. Decoded
//! strings are slices of the input, so a reply lives as long as its bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ BadProtobuf, OutOfMemory };

// The messages, in the order of nix_remote.proto.

pub const Chunk = struct {
    data: []const u8 = "",
    pub const tags = .{ .data = 1 };
};

pub const QueryValidPathsRequest = struct {
    paths: []const []const u8 = &.{},
    substitute: bool = false,
    pub const tags = .{ .paths = 1, .substitute = 2 };
};

pub const QueryValidPathsReply = struct {
    paths: []const []const u8 = &.{},
    pub const tags = .{ .paths = 1 };
};

pub const AddMultipleChunk = struct {
    repair: bool = false,
    check_sigs: bool = false,
    data: []const u8 = "",
    pub const tags = .{ .repair = 1, .check_sigs = 2, .data = 3 };
};

pub const AddMultipleReply = struct {
    pub const tags = .{};
};

pub const QueryPathInfosRequest = struct {
    paths: []const []const u8 = &.{},
    pub const tags = .{ .paths = 1 };
};

pub const PathInfo = struct {
    path: []const u8 = "",
    info: []const u8 = "",
    pub const tags = .{ .path = 1, .info = 2 };
};

pub const QueryPathInfosReply = struct {
    infos: []const PathInfo = &.{},
    pub const tags = .{ .infos = 1 };
};

pub const BuildDerivationRequest = struct {
    drv_path: []const u8 = "",
    drv: []const u8 = "",
    build_mode: u32 = 0,
    protocol: u32 = 0,
    assign_id: u64 = 0,
    pub const tags = .{ .drv_path = 1, .drv = 2, .build_mode = 3, .protocol = 4, .assign_id = 5 };
};

pub const BuildDerivationDone = struct {
    result: []const u8 = "",
    outputs: []const PathInfo = &.{},
    pub const tags = .{ .result = 1, .outputs = 2 };
};

pub const BuildDerivationChunk = struct {
    event: ?Event = null,
    pub const tags = .{ .event = 0 };

    pub const Event = union(enum) {
        log_line: []const u8,
        done: BuildDerivationDone,
        phase: []const u8,
        pub const tags = .{ .log_line = 1, .done = 2, .phase = 3 };
    };
};

pub const QueryMissingRequest = struct {
    targets: []const []const u8 = &.{},
    pub const tags = .{ .targets = 1 };
};

pub const QueryMissingReply = struct {
    will_build: []const []const u8 = &.{},
    will_substitute: []const []const u8 = &.{},
    unknown: []const []const u8 = &.{},
    download_size: u64 = 0,
    nar_size: u64 = 0,
    pub const tags = .{ .will_build = 1, .will_substitute = 2, .unknown = 3, .download_size = 4, .nar_size = 5 };
};

pub const StoreInfoRequest = struct {
    pub const tags = .{};
};

pub const StoreInfoReply = struct {
    trusted: ?bool = null,
    pub const tags = .{ .trusted = 1 };
};

pub const FetchNarsRequest = struct {
    paths: []const []const u8 = &.{},
    pub const tags = .{ .paths = 1 };
};

pub const NarFrame = struct {
    path_index: u32 = 0,
    data: []const u8 = "",
    eof: bool = false,
    pub const tags = .{ .path_index = 1, .data = 2, .eof = 3 };
};

pub const Want = struct {
    drv_path: []const u8 = "",
    out_keys: []const []const u8 = &.{},
    inputs: []const []const u8 = &.{},
    cp_hint_ms: u64 = 0,
    build_mode: u32 = 0,
    required_features: []const []const u8 = &.{},
    system: []const u8 = "",
    pub const tags = .{ .drv_path = 1, .out_keys = 2, .inputs = 3, .cp_hint_ms = 4, .build_mode = 5, .required_features = 6, .system = 7 };
};

pub const Cancel = struct {
    drv_path: []const u8 = "",
    pub const tags = .{ .drv_path = 1 };
};

pub const ClientMsg = struct {
    msg: ?Msg = null,
    pub const tags = .{ .msg = 0 };

    pub const Msg = union(enum) {
        want: Want,
        cancel: Cancel,
        pub const tags = .{ .want = 1, .cancel = 2 };
    };
};

pub const Assigned = struct {
    drv_path: []const u8 = "",
    worker_addr: []const u8 = "",
    assign_id: u64 = 0,
    pub const tags = .{ .drv_path = 1, .worker_addr = 2, .assign_id = 3 };
};

pub const Cached = struct {
    drv_path: []const u8 = "",
    pub const tags = .{ .drv_path = 1 };
};

pub const Unplaceable = struct {
    drv_path: []const u8 = "",
    reason: []const u8 = "",
    pub const tags = .{ .drv_path = 1, .reason = 2 };
};

pub const Restarting = struct {
    pub const tags = .{};
};

pub const SchedMsg = struct {
    msg: ?Msg = null,
    pub const tags = .{ .msg = 0 };

    pub const Msg = union(enum) {
        assigned: Assigned,
        cached: Cached,
        unplaceable: Unplaceable,
        restarting: Restarting,
        pub const tags = .{ .assigned = 1, .cached = 2, .unplaceable = 3, .restarting = 4 };
    };
};

pub const ClientMsgs = struct {
    msgs: []const ClientMsg = &.{},
    pub const tags = .{ .msgs = 1 };
};

pub const SchedMsgs = struct {
    msgs: []const SchedMsg = &.{},
    pub const tags = .{ .msgs = 1 };
};

// The codec.

const WireType = enum(u3) { varint = 0, i64 = 1, len = 2, sgroup = 3, egroup = 4, i32 = 5 };

fn varintLen(v: u64) usize {
    if (v == 0) return 1;
    return (64 - @clz(v) + 6) / 7;
}

fn putVarint(out: []u8, v0: u64) usize {
    var v = v0;
    var i: usize = 0;
    while (v >= 0x80) : (i += 1) {
        out[i] = @as(u8, @truncate(v)) | 0x80;
        v >>= 7;
    }
    out[i] = @truncate(v);
    return i + 1;
}

fn key(tag: u32, wt: WireType) u64 {
    return (@as(u64, tag) << 3) | @backingInt(wt);
}

fn tagOf(comptime T: type, comptime name: []const u8) u32 {
    return @field(T.tags, name);
}

/// Whether `F` is a message (a struct with `tags`).
fn isMessage(comptime F: type) bool {
    return @typeInfo(F) == .@"struct" and @hasDecl(F, "tags");
}

fn isOneof(comptime F: type) bool {
    return @typeInfo(F) == .optional and @typeInfo(@typeInfo(F).optional.child) == .@"union";
}

fn lenField(tag: u32, n: usize) usize {
    return varintLen(key(tag, .len)) + varintLen(n) + n;
}

/// The size of `m` encoded.
pub fn encodedLen(m: anytype) usize {
    const T = @TypeOf(m);
    var n: usize = 0;
    inline for (comptime fieldsOf(T)) |f| {
        const v = @field(m, f.name);
        if (comptime isOneof(f.type)) {
            if (v) |u| n += unionLen(u);
        } else n += fieldLen(f.type, tagOf(T, f.name), v);
    }
    return n;
}

fn unionLen(u: anytype) usize {
    const U = @TypeOf(u);
    switch (u) {
        inline else => |v, t| {
            const tag = tagOf(U, @tagName(t));
            const F = @TypeOf(v);
            if (F == []const u8) return lenField(tag, v.len);
            return lenField(tag, encodedLen(v));
        },
    }
}

fn fieldLen(comptime F: type, tag: u32, v: F) usize {
    return switch (F) {
        []const u8 => if (v.len == 0) 0 else lenField(tag, v.len),
        bool => if (v) varintLen(key(tag, .varint)) + 1 else 0,
        ?bool => if (v != null) varintLen(key(tag, .varint)) + 1 else 0,
        u32, u64 => if (v == 0) 0 else varintLen(key(tag, .varint)) + varintLen(v),
        []const []const u8 => blk: {
            var n: usize = 0;
            for (v) |s| n += lenField(tag, s.len);
            break :blk n;
        },
        else => switch (@typeInfo(F)) {
            .pointer => |p| blk: {
                var n: usize = 0;
                for (v) |e| n += lenField(tag, encodedLen(@as(p.child, e)));
                break :blk n;
            },
            .optional => if (v) |e| lenField(tag, encodedLen(e)) else 0,
            else => @compileError("no protobuf mapping for " ++ @typeName(F)),
        },
    };
}

/// Writes `m` into `out`, which must hold exactly `encodedLen(m)` bytes;
/// returns how many were written.
pub fn encodeInto(out: []u8, m: anytype) usize {
    const T = @TypeOf(m);
    var o: usize = 0;
    inline for (comptime fieldsOf(T)) |f| {
        const v = @field(m, f.name);
        if (comptime isOneof(f.type)) {
            if (v) |u| o += encodeUnion(out[o..], u);
        } else o += encodeField(out[o..], f.type, tagOf(T, f.name), v);
    }
    return o;
}

/// The most bytes `putLen` writes.
pub const max_len_head = 2 * 10;

/// The key and length of field `tag` holding `n` bytes, the head the bytes
/// follow on the wire: a message of one bytes field is this head and the
/// bytes, which a caller can then send without copying them.
pub fn putLen(out: []u8, tag: u32, n: usize) usize {
    var o = putVarint(out, key(tag, .len));
    o += putVarint(out[o..], n);
    return o;
}

fn putBytes(out: []u8, tag: u32, s: []const u8) usize {
    const o = putLen(out, tag, s.len);
    @memcpy(out[o..][0..s.len], s);
    return o + s.len;
}

fn putMessage(out: []u8, tag: u32, m: anytype) usize {
    const n = encodedLen(m);
    const o = putLen(out, tag, n);
    return o + encodeInto(out[o..][0..n], m);
}

fn encodeUnion(out: []u8, u: anytype) usize {
    const U = @TypeOf(u);
    switch (u) {
        inline else => |v, t| {
            const tag = tagOf(U, @tagName(t));
            if (@TypeOf(v) == []const u8) return putBytes(out, tag, v);
            return putMessage(out, tag, v);
        },
    }
}

fn encodeField(out: []u8, comptime F: type, tag: u32, v: F) usize {
    switch (F) {
        []const u8 => return if (v.len == 0) 0 else putBytes(out, tag, v),
        bool => {
            if (!v) return 0;
            const o = putVarint(out, key(tag, .varint));
            out[o] = 1;
            return o + 1;
        },
        ?bool => {
            const b = v orelse return 0;
            const o = putVarint(out, key(tag, .varint));
            out[o] = @intFromBool(b);
            return o + 1;
        },
        u32, u64 => {
            if (v == 0) return 0;
            const o = putVarint(out, key(tag, .varint));
            return o + putVarint(out[o..], v);
        },
        []const []const u8 => {
            var o: usize = 0;
            for (v) |s| o += putBytes(out[o..], tag, s);
            return o;
        },
        else => switch (@typeInfo(F)) {
            .pointer => {
                var o: usize = 0;
                for (v) |e| o += putMessage(out[o..], tag, e);
                return o;
            },
            .optional => return if (v) |e| putMessage(out, tag, e) else 0,
            else => @compileError("no protobuf mapping for " ++ @typeName(F)),
        },
    }
}

/// `m` encoded, in `gpa`.
pub fn encodeAlloc(gpa: Allocator, m: anytype) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, encodedLen(m));
    std.debug.assert(encodeInto(out, m) == out.len);
    return out;
}

const Cursor = struct {
    b: []const u8,
    i: usize = 0,

    fn varint(c: *Cursor) Error!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            if (c.i >= c.b.len) return error.BadProtobuf;
            const byte = c.b[c.i];
            c.i += 1;
            if (shift == 63 and byte > 1) return error.BadProtobuf;
            v |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return v;
            shift += 7;
            if (shift > 63) return error.BadProtobuf;
        }
    }

    fn bytes(c: *Cursor) Error![]const u8 {
        const n = try c.varint();
        if (n > c.b.len - c.i) return error.BadProtobuf;
        const s = c.b[c.i..][0..@intCast(n)];
        c.i += @intCast(n);
        return s;
    }

    fn skip(c: *Cursor, wt: u3) Error!void {
        switch (wt) {
            0 => _ = try c.varint(),
            1 => {
                if (c.b.len - c.i < 8) return error.BadProtobuf;
                c.i += 8;
            },
            2 => _ = try c.bytes(),
            5 => {
                if (c.b.len - c.i < 4) return error.BadProtobuf;
                c.i += 4;
            },
            else => return error.BadProtobuf,
        }
    }
};

/// Decodes a `T` from `b`. Repeated fields are allocated in `arena`; strings
/// and bytes are slices of `b`. Unknown fields are skipped; of a repeated
/// singular field the last wins, as protobuf has it.
pub fn decode(comptime T: type, arena: Allocator, b: []const u8) Error!T {
    var m: T = .{};
    var c: Cursor = .{ .b = b };
    // repeated fields collect here, then become slices
    var lists: Lists(T) = .{};
    while (c.i < b.len) {
        const k = try c.varint();
        const wt: u3 = @truncate(k);
        const tag = std.math.cast(u32, k >> 3) orelse return error.BadProtobuf;
        if (tag == 0) return error.BadProtobuf;
        if (!try decodeField(T, arena, &m, &lists, tag, wt, &c)) try c.skip(wt);
    }
    inline for (comptime fieldsOf(T)) |f| {
        if (comptime isRepeated(f.type)) @field(m, f.name) = try @field(lists, f.name).toOwnedSlice(arena);
    }
    return m;
}

fn isRepeated(comptime F: type) bool {
    return @typeInfo(F) == .pointer and F != []const u8;
}

const FieldDesc = struct { name: [:0]const u8, type: type };

fn fieldsOf(comptime T: type) []const FieldDesc {
    const info = @typeInfo(T).@"struct";
    var out: [info.field_names.len]FieldDesc = undefined;
    for (&out, info.field_names, info.field_types) |*o, n, t| o.* = .{ .name = n, .type = t };
    const final = out;
    return &final;
}

fn unionFields(comptime U: type) []const FieldDesc {
    const info = @typeInfo(U).@"union";
    var out: [info.field_names.len]FieldDesc = undefined;
    for (&out, info.field_names, info.field_types) |*o, n, t| o.* = .{ .name = n, .type = t };
    const final = out;
    return &final;
}

fn Lists(comptime T: type) type {
    var names: []const [:0]const u8 = &.{};
    var types: []const type = &.{};
    for (comptime fieldsOf(T)) |f| if (isRepeated(f.type)) {
        names = names ++ [_][:0]const u8{f.name};
        types = types ++ [_]type{std.ArrayList(@typeInfo(f.type).pointer.child)};
    };
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (&attrs, types) |*a, L| a.* = .{ .default_value_ptr = @ptrCast(&@as(L, .empty)) };
    const n = names[0..names.len].*;
    const t = types[0..types.len].*;
    return @Struct(.auto, null, &n, &t, &attrs);
}

fn decodeField(comptime T: type, arena: Allocator, m: *T, lists: *Lists(T), tag: u32, wt: u3, c: *Cursor) Error!bool {
    inline for (comptime fieldsOf(T)) |f| {
        if (comptime isOneof(f.type)) {
            const U = @typeInfo(f.type).optional.child;
            inline for (comptime unionFields(U)) |uf| {
                if (tag == tagOf(U, uf.name)) {
                    if (wt != 2) return error.BadProtobuf;
                    const s = try c.bytes();
                    @field(m, f.name) = @unionInit(U, uf.name, if (uf.type == []const u8) s else try decode(uf.type, arena, s));
                    return true;
                }
            }
        } else if (tag == tagOf(T, f.name)) {
            const F = f.type;
            switch (F) {
                []const u8 => {
                    if (wt != 2) return error.BadProtobuf;
                    @field(m, f.name) = try c.bytes();
                },
                bool, ?bool => {
                    if (wt != 0) return error.BadProtobuf;
                    @field(m, f.name) = try c.varint() != 0;
                },
                u32 => {
                    if (wt != 0) return error.BadProtobuf;
                    @field(m, f.name) = @truncate(try c.varint());
                },
                u64 => {
                    if (wt != 0) return error.BadProtobuf;
                    @field(m, f.name) = try c.varint();
                },
                []const []const u8 => {
                    if (wt != 2) return error.BadProtobuf;
                    try @field(lists, f.name).append(arena, try c.bytes());
                },
                else => switch (@typeInfo(F)) {
                    .pointer => |p| {
                        if (wt != 2) return error.BadProtobuf;
                        try @field(lists, f.name).append(arena, try decode(p.child, arena, try c.bytes()));
                    },
                    .optional => |o| {
                        if (wt != 2) return error.BadProtobuf;
                        @field(m, f.name) = try decode(o.child, arena, try c.bytes());
                    },
                    else => @compileError("no protobuf mapping for " ++ @typeName(F)),
                },
            }
            return true;
        }
    }
    return false;
}

// Tests: the bytes are what protoc's encoder gives for the same messages.

const testing = std.testing;

test "scalars, strings and repeated strings encode as protoc does" {
    const m: QueryValidPathsRequest = .{ .paths = &.{ "a", "bc" }, .substitute = true };
    var buf: [64]u8 = undefined;
    const n = encodeInto(buf[0..encodedLen(m)], m);
    try testing.expectEqualSlices(u8, &.{ 0x0a, 1, 'a', 0x0a, 2, 'b', 'c', 0x10, 1 }, buf[0..n]);
    const back = try decode(QueryValidPathsRequest, testing.allocator, buf[0..n]);
    defer testing.allocator.free(back.paths);
    try testing.expectEqual(2, back.paths.len);
    try testing.expectEqualStrings("bc", back.paths[1]);
    try testing.expect(back.substitute);
}

test "defaults are not on the wire, an optional bool is" {
    try testing.expectEqual(0, encodedLen(NarFrame{}));
    try testing.expectEqual(0, encodedLen(StoreInfoReply{}));
    const m: StoreInfoReply = .{ .trusted = false };
    var buf: [4]u8 = undefined;
    const n = encodeInto(buf[0..encodedLen(m)], m);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0 }, buf[0..n]);
    try testing.expectEqual(false, (try decode(StoreInfoReply, testing.allocator, buf[0..n])).trusted.?);
    try testing.expectEqual(null, (try decode(StoreInfoReply, testing.allocator, "")).trusted);
}

test "a oneof and nested messages round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want: Want = .{ .drv_path = "x.drv", .out_keys = &.{"k.narinfo"}, .cp_hint_ms = 300, .build_mode = 1, .system = "x86_64-linux" };
    const msgs: ClientMsgs = .{ .msgs = &.{ .{ .msg = .{ .want = want } }, .{ .msg = .{ .cancel = .{ .drv_path = "y.drv" } } } } };
    const bytes = try encodeAlloc(a, msgs);
    const back = try decode(ClientMsgs, a, bytes);
    try testing.expectEqual(2, back.msgs.len);
    const w = back.msgs[0].msg.?.want;
    try testing.expectEqualStrings("x.drv", w.drv_path);
    try testing.expectEqualStrings("k.narinfo", w.out_keys[0]);
    try testing.expectEqual(300, w.cp_hint_ms);
    try testing.expectEqualStrings("x86_64-linux", w.system);
    try testing.expectEqualStrings("y.drv", back.msgs[1].msg.?.cancel.drv_path);

    const chunk: BuildDerivationChunk = .{ .event = .{ .done = .{ .result = "r", .outputs = &.{.{ .path = "p", .info = "i" }} } } };
    const cb = try encodeAlloc(a, chunk);
    // field 2, length-delimited, holding field 1 "r" and field 2 {1:"p",2:"i"}
    try testing.expectEqualSlices(u8, &.{ 0x12, 11, 0x0a, 1, 'r', 0x12, 6, 0x0a, 1, 'p', 0x12, 1, 'i' }, cb);
    const done = (try decode(BuildDerivationChunk, a, cb)).event.?.done;
    try testing.expectEqualStrings("i", done.outputs[0].info);
    // an empty message in a oneof is still present
    const r = try encodeAlloc(a, SchedMsg{ .msg = .{ .restarting = .{} } });
    try testing.expectEqualSlices(u8, &.{ 0x22, 0 }, r);
    try testing.expect((try decode(SchedMsg, a, r)).msg.? == .restarting);
}

test "unknown fields are skipped, malformed input refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // field 9 varint, field 10 fixed64, field 11 bytes, field 12 fixed32, then path_index 7
    const b = [_]u8{ 0x48, 0x96, 0x01, 0x51 } ++ @as([8]u8, @splat(0)) ++ [_]u8{ 0x5a, 1, 'z', 0x65, 0, 0, 0, 0, 0x08, 7 };
    try testing.expectEqual(7, (try decode(NarFrame, a, &b)).path_index);
    try testing.expectError(error.BadProtobuf, decode(NarFrame, a, &.{ 0x12, 5, 'a' }));
    try testing.expectError(error.BadProtobuf, decode(NarFrame, a, &.{0x80}));
    try testing.expectError(error.BadProtobuf, decode(NarFrame, a, &.{ 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f }));
    try testing.expectError(error.BadProtobuf, decode(NarFrame, a, &.{ 0x0a, 0 }));
    try testing.expectError(error.BadProtobuf, decode(NarFrame, a, &.{ 0x00, 0 }));
}

test "large varints" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const m: Assigned = .{ .assign_id = std.math.maxInt(u64), .worker_addr = "10.0.0.1:1" };
    const b = try encodeAlloc(arena.allocator(), m);
    const back = try decode(Assigned, arena.allocator(), b);
    try testing.expectEqual(std.math.maxInt(u64), back.assign_id);
    try testing.expectEqualStrings("10.0.0.1:1", back.worker_addr);
}
