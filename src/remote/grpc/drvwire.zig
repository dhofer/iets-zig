//! The worker-protocol serialisations the gRPC messages carry as opaque
//! bytes: `BasicDerivation` in a `BuildDerivationRequest`, `BuildResult` in
//! the replies, and `UnkeyedValidPathInfo` at protocol 1.16 in a `PathInfo`.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../../diag.zig").Diag;
const remote = @import("../../remote.zig");
const path_mod = @import("../../store/path.zig");
const StorePath = path_mod.StorePath;
const drv_mod = @import("../../store/drv.zig");
const Derivation = drv_mod.Derivation;
const wire = @import("../worker/wire.zig");

/// nix-compat.hh:`kBuildProtocolWire`: `major << 8 | minor`. The daemon
/// rejects anything else with `INVALID_ARGUMENT`.
pub const build_protocol: u32 = (1 << 8) | 37;

/// derivation/aterm.cc:`write(Sink &, const StoreDirConfig &, const Basic &)`.
/// `name` is not on the wire: the reader takes it from the drv path.
/// `input_srcs` comes from `basicInputSrcs`.
pub fn writeBasicDerivation(w: *Writer, drv: *const Derivation, input_srcs: []const StorePath, d: *Diag) (Writer.Error || error{Store})!void {
    var pbuf: [path_mod.max_base_len + 256]u8 = undefined;
    var hbuf: [128]u8 = undefined;
    try wire.writeU64(w, drv.outputs.len);
    for (drv.outputs) |o| {
        try wire.writeStr(w, o.name);
        switch (o.output) {
            .input_addressed => |p| {
                try wire.writeStr(w, p.print(&pbuf));
                try wire.writeStr(w, "");
                try wire.writeStr(w, "");
            },
            .fixed => |f| {
                const p = drv.fixedOutputPath(o.name, d) catch
                    return d.fail(error.Store, "output '{s}' has no fixed path", .{o.name});
                try wire.writeStr(w, p.print(&pbuf));
                try wire.writeStr(w, std.fmt.bufPrint(&hbuf, "{s}{s}", .{ f.method.prefix(), f.hash.algo.name() }) catch unreachable);
                var b16: [256]u8 = undefined;
                try wire.writeStr(w, f.hash.print(&b16, .base16, false));
            },
            .ca_floating => |f| {
                try wire.writeStr(w, "");
                try wire.writeStr(w, std.fmt.bufPrint(&hbuf, "{s}{s}", .{ f.method.prefix(), f.algo.name() }) catch unreachable);
                try wire.writeStr(w, "");
            },
            .deferred => for (0..3) |_| try wire.writeStr(w, ""),
        }
    }
    try wire.writePaths(w, input_srcs);
    try wire.writeStr(w, drv.platform);
    try wire.writeStr(w, drv.builder);
    try wire.writeStrs(w, drv.args);
    // StructuredAttrs::unparse puts the JSON back under `__json`; the env
    // map is sorted by key, so the entry goes where its key belongs.
    const env = drv.env.items;
    try wire.writeU64(w, env.len + @intFromBool(drv.structured_attrs != null));
    var json_done = drv.structured_attrs == null;
    for (env) |e| {
        if (!json_done and std.mem.order(u8, drv_mod.structured_attrs_env, e.key) == .lt) {
            try wire.writeStr(w, drv_mod.structured_attrs_env);
            try wire.writeStr(w, drv.structured_attrs.?);
            json_done = true;
        }
        try wire.writeStr(w, e.key);
        try wire.writeStr(w, e.value);
    }
    if (!json_done) {
        try wire.writeStr(w, drv_mod.structured_attrs_env);
        try wire.writeStr(w, drv.structured_attrs.?);
    }
}

/// worker-protocol.cc:`Serialise<BuildResult>`, at protocol 1.37 with no
/// negotiated features (so `builtOutputs` is the legacy `StringMap` keyed
/// `<dummy hash>!<output name>` with JSON values).
pub const BuildResult = struct {
    status: u64 = 0,
    error_msg: []const u8 = "",
    times_built: u64 = 0,
    is_non_deterministic: bool = false,
    start_time: u64 = 0,
    stop_time: u64 = 0,
    cpu_user_us: ?u64 = null,
    cpu_system_us: ?u64 = null,
    /// Output name to store path, from `builtOutputs`, sorted by name.
    built_outputs: []const Output = &.{},

    pub const Output = struct { name: []const u8, path: []const u8 };

    /// common-protocol.cc:`buildResultStatusTable`: Built, Substituted,
    /// AlreadyValid, ResolvesToAlreadyValid.
    pub fn success(r: *const BuildResult) bool {
        return switch (r.status) {
            0, 1, 2, 13 => true,
            else => false,
        };
    }

    pub fn builtOutput(r: *const BuildResult, name: []const u8) ?[]const u8 {
        for (r.built_outputs) |o| if (std.mem.eql(u8, o.name, name)) return o.path;
        return null;
    }

    /// `TransientFailure` (6) is what the daemon turns into `UNAVAILABLE`
    /// for a retry; the others are the build's own verdict.
    pub fn read(r: *Reader, arena: Allocator, d: *Diag) wire.ReadError!BuildResult {
        var res: BuildResult = .{
            .status = try wire.readU64(r, d),
            .error_msg = try wire.readStr(r, arena, d),
        };
        res.times_built = try wire.readU64(r, d);
        res.is_non_deterministic = try wire.readU64(r, d) != 0;
        res.start_time = try wire.readU64(r, d);
        res.stop_time = try wire.readU64(r, d);
        res.cpu_user_us = try readOptU64(r, d);
        res.cpu_system_us = try readOptU64(r, d);
        const n = try wire.readU64(r, d);
        var outs: std.ArrayList(Output) = .empty;
        for (0..n) |_| {
            const key = try wire.readStr(r, arena, d);
            const json = try wire.readStr(r, arena, d);
            const name = if (std.mem.indexOfScalar(u8, key, '!')) |i| key[i + 1 ..] else key;
            const path = outPath(arena, json) orelse continue;
            try outs.append(arena, .{ .name = name, .path = path });
        }
        // a BTreeMap: sorted, the last of equal keys wins
        std.mem.sort(Output, outs.items, {}, struct {
            fn lt(_: void, a: Output, b: Output) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        var kept: usize = 0;
        for (outs.items) |o| {
            if (kept > 0 and std.mem.eql(u8, outs.items[kept - 1].name, o.name)) {
                outs.items[kept - 1] = o;
                continue;
            }
            outs.items[kept] = o;
            kept += 1;
        }
        res.built_outputs = outs.items[0..kept];
        return res;
    }
};

fn outPath(arena: Allocator, json: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return null;
    const o = switch (v) {
        .object => |o| o,
        else => return null,
    };
    return switch (o.get("outPath") orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn readOptU64(r: *Reader, d: *Diag) wire.ReadError!?u64 {
    if (try wire.readU64(r, d) == 1) return try wire.readU64(r, d);
    return null;
}

/// One path's `UnkeyedValidPathInfo` at protocol 1.16, as it arrives in a
/// `PathInfo` message (path-info-wire.hh:`encodePathInfo`). Strings live in
/// the arena the reader was given.
pub const PathInfo = struct {
    path: StorePath,
    deriver: []const u8,
    /// Base16, as the wire carries it.
    nar_hash: []const u8,
    references: []const []const u8,
    registration_time: u64,
    nar_size: u64,
    ultimate: bool,
    sigs: []const []const u8,
    ca: []const u8,

    /// `base` is a store path base name; `info` the 1.16 bytes.
    pub fn decode(arena: Allocator, base: []const u8, info: []const u8, d: *Diag) remote.Error!PathInfo {
        const p = StorePath.fromBaseName(base, d) catch return error.Store;
        var r: Reader = .fixed(info);
        return fields(arena, p, &r, d) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Io => error.Io,
        };
    }

    /// The same fields straight off a worker-protocol connection, where
    /// `path` is the full store path the caller asked `QueryPathInfo` about.
    pub fn read(arena: Allocator, path: []const u8, r: *Reader, d: *Diag) remote.Error!PathInfo {
        const p = StorePath.parse(path, d) catch return error.Store;
        return fields(arena, p, r, d) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Io => error.Io,
        };
    }

    fn fields(arena: Allocator, path: StorePath, r: *Reader, d: *Diag) wire.ReadError!PathInfo {
        const deriver = try wire.readOptPath(r, arena, d);
        const nar_hash = try wire.narHash(arena, try wire.readStr(r, arena, d), d);
        const references = try wire.readPaths(r, arena, d);
        const registration_time = try wire.readTime(r, d);
        const nar_size = try wire.readU64(r, d);
        const ultimate = try wire.readBool(r, d);
        const sigs = try wire.readStrs(r, arena, d);
        for (sigs) |*s| s.* = try wire.signature(arena, s.*, d);
        const ca = try wire.contentAddress(arena, try wire.readStr(r, arena, d), d);
        return .{
            .path = path,
            .deriver = deriver,
            .nar_hash = nar_hash,
            .references = references,
            .registration_time = registration_time,
            .nar_size = nar_size,
            .ultimate = ultimate,
            .sigs = sigs,
            .ca = ca,
        };
    }

    /// The `ValidPathInfo` an `AddMultipleToStore` body wants for this path
    /// (worker-protocol.cc:`Serialise<ValidPathInfo>` at 1.16): the path,
    /// then the same fields back, signatures included, so a local daemon can
    /// verify what the farm signed.
    pub fn write(p: *const PathInfo, w: *Writer) Writer.Error!void {
        var buf: [path_mod.max_base_len + 256]u8 = undefined;
        try wire.writeStr(w, p.path.print(&buf));
        try wire.writeStr(w, p.deriver);
        try wire.writeStr(w, p.nar_hash);
        try wire.writeStrs(w, p.references);
        try wire.writeU64(w, p.registration_time);
        try wire.writeU64(w, p.nar_size);
        try wire.writeU64(w, @intFromBool(p.ultimate));
        try wire.writeStrs(w, p.sigs);
        try wire.writeStr(w, p.ca);
    }
};

/// Looks up the statically known path of `dep!output`.
pub const OutputOf = struct {
    ctx: ?*const anyopaque,
    f: *const fn (ctx: ?*const anyopaque, dep: *const StorePath, output: []const u8) ?StorePath,
};

/// Turns a `Derivation` into the `input_srcs` a `BasicDerivation` carries:
/// its own `inputSrcs` plus the output path of every input derivation
/// output (nix-compat.hh:`toBasicDrv`), sorted and unique, in `arena`.
pub fn basicInputSrcs(arena: Allocator, drv_path: *const StorePath, drv: *const Derivation, output_of: OutputOf, d: *Diag) remote.Error![]StorePath {
    var srcs: std.ArrayList(StorePath) = .empty;
    try srcs.appendSlice(arena, drv.input_srcs);
    for (drv.input_drvs) |in| for (in.node.outputs) |o| {
        const p = output_of.f(output_of.ctx, &in.path, o) orelse
            return d.fail(error.Plan, "'{f}': input '{f}!{s}' has no statically known path; " ++
                "the build farm needs statically known input and output paths", .{ drv_path, &in.path, o });
        try srcs.append(arena, p);
    };
    return path_mod.sortUnique(srcs.items);
}

// Tests

const testing = std.testing;

const aterm =
    \\Derive([("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo","","")],[("/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-dep.drv",["out"])],["/nix/store/cccccccccccccccccccccccccccccccc-src"],"x86_64-linux","/bin/sh",["-c","true"],[("__json","{\"a\":1}"),("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo"),("zz","last")])
;

// Reproduces `derivation::write` by hand: the field order and the empty
// hash-algo/hash strings for an input-addressed output.
test "basic derivation matches the cxx field order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const drv = try Derivation.parse(a, aterm, "foo", &d);
    const dep_out = try StorePath.parse("/nix/store/dddddddddddddddddddddddddddddddd-dep-out", &d);
    const self = try StorePath.parse("/nix/store/ffffffffffffffffffffffffffffffff-foo.drv", &d);
    const srcs = try basicInputSrcs(a, &self, &drv, .{ .ctx = &dep_out, .f = struct {
        fn f(ctx: ?*const anyopaque, _: *const StorePath, _: []const u8) ?StorePath {
            return @as(*const StorePath, @ptrCast(@alignCast(ctx.?))).*;
        }
    }.f }, &d);
    var got: Writer.Allocating = .init(a);
    try writeBasicDerivation(&got.writer, &drv, srcs, &d);

    var want: Writer.Allocating = .init(a);
    const w = &want.writer;
    try wire.writeU64(w, 1);
    try wire.writeStr(w, "out");
    try wire.writeStr(w, "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo");
    try wire.writeStr(w, "");
    try wire.writeStr(w, "");
    // inputSrcs, sorted by base name: the src then the resolved dep output.
    try wire.writeStrs(w, &.{ "/nix/store/cccccccccccccccccccccccccccccccc-src", "/nix/store/dddddddddddddddddddddddddddddddd-dep-out" });
    try wire.writeStr(w, "x86_64-linux");
    try wire.writeStr(w, "/bin/sh");
    try wire.writeStrs(w, &.{ "-c", "true" });
    try wire.writeU64(w, 3);
    for ([_][2][]const u8{
        .{ "__json", "{\"a\":1}" },
        .{ "out", "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo" },
        .{ "zz", "last" },
    }) |kv| {
        try wire.writeStr(w, kv[0]);
        try wire.writeStr(w, kv[1]);
    }
    try testing.expectEqualSlices(u8, want.written(), got.written());
}

test "an unresolvable input output is an error" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const drv = try Derivation.parse(a, aterm, "foo", &d);
    const self = try StorePath.parse("/nix/store/ffffffffffffffffffffffffffffffff-foo.drv", &d);
    try testing.expectError(error.Plan, basicInputSrcs(a, &self, &drv, .{ .ctx = null, .f = struct {
        fn f(_: ?*const anyopaque, _: *const StorePath, _: []const u8) ?StorePath {
            return null;
        }
    }.f }, &d));
}

test "build result round trips a daemon reply" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bytes: Writer.Allocating = .init(a);
    const w = &bytes.writer;
    try wire.writeU64(w, 0); // Built
    try wire.writeStr(w, "");
    try wire.writeU64(w, 1); // timesBuilt
    try wire.writeU64(w, 0); // isNonDeterministic
    try wire.writeU64(w, 1000);
    try wire.writeU64(w, 1042);
    try wire.writeU64(w, 1); // cpuUser present
    try wire.writeU64(w, 12345);
    try wire.writeU64(w, 0); // cpuSystem absent
    try wire.writeU64(w, 1); // one built output
    try wire.writeStr(w, "sha256:0000!out");
    try wire.writeStr(w, "{\"id\":\"sha256:0000!out\",\"outPath\":\"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo\"}");
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var r: Reader = .fixed(bytes.written());
    const res = try BuildResult.read(&r, a, &d);
    try testing.expect(res.success());
    try testing.expectEqual(1, res.times_built);
    try testing.expectEqual(1042, res.stop_time);
    try testing.expectEqual(12345, res.cpu_user_us.?);
    try testing.expectEqual(null, res.cpu_system_us);
    try testing.expectEqualStrings("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo", res.builtOutput("out").?);
}

test "a failure keeps its message" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var bytes: Writer.Allocating = .init(a);
    const w = &bytes.writer;
    try wire.writeU64(w, 3); // PermanentFailure
    try wire.writeStr(w, "builder failed");
    for (0..7) |_| try wire.writeU64(w, 0);
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var r: Reader = .fixed(bytes.written());
    const res = try BuildResult.read(&r, a, &d);
    try testing.expect(!res.success());
    try testing.expectEqualStrings("builder failed", res.error_msg);
}

test "path info round trips" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const zeros: [64]u8 = @splat('0');
    const info: PathInfo = .{
        .path = try StorePath.fromBaseName("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-foo", &d),
        .deriver = "/nix/store/ffffffffffffffffffffffffffffffff-foo.drv",
        .nar_hash = &zeros,
        .references = &.{"/nix/store/cccccccccccccccccccccccccccccccc-src"},
        .registration_time = 7,
        .nar_size = 4096,
        .ultimate = false,
        .sigs = &.{"cache.numtide.com-1:abc="},
        .ca = "",
    };
    // `write` prefixes the path, `decode` takes it out of band, so drop it.
    var bytes: Writer.Allocating = .init(a);
    try info.write(&bytes.writer);
    var r: Reader = .fixed(bytes.written());
    var pbuf: [512]u8 = undefined;
    try testing.expectEqualStrings(info.path.print(&pbuf), try wire.readStr(&r, a, &d));
    const decoded = try PathInfo.decode(a, info.path.baseName(), r.buffered(), &d);
    try testing.expect(decoded.path.eql(&info.path));
    try testing.expectEqualStrings(info.deriver, decoded.deriver);
    try testing.expectEqualStrings(info.nar_hash, decoded.nar_hash);
    try testing.expectEqualStrings(info.references[0], decoded.references[0]);
    try testing.expectEqual(7, decoded.registration_time);
    try testing.expectEqual(4096, decoded.nar_size);
    try testing.expectEqualStrings(info.sigs[0], decoded.sigs[0]);
    try testing.expectEqualStrings("", decoded.ca);
}
