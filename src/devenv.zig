//! `iets print-dev-env`: the shell environment of a derivation, computed as
//! `nix print-dev-env` (src/nix/develop.cc, Nix 2.34.8) computes it. This module
//! holds the pure parts: the `-env` derivation, the JSON `get-env.sh` writes,
//! and the bash `makeRcScript` prints. The daemon flow lives in `cli/devenv.zig`.
//! See docs/reference/commands.md.

const std = @import("std");
const text_ = @import("syntax/text.zig");
const errors = @import("errors.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = Io.Writer;
const Diag = @import("diag.zig").Diag;
const drv_mod = @import("store/drv.zig");
const Derivation = drv_mod.Derivation;
const hash_mod = @import("store/hash.zig");
const path_mod = @import("store/path.zig");
const StorePath = path_mod.StorePath;
const store_json = @import("store/json.zig");
const sys = @import("sys.zig");

pub const Error = drv_mod.Error || error{ Protocol, Store, Io };

/// src/nix/get-env.sh, verbatim: the builder script of the `-env` derivation. Nix embeds
/// the file through `get-env.sh.gen.hh`, a raw string literal whose opening delimiter is
/// followed by a newline, so the text Nix adds to the store starts with one.
pub const get_env_sh = "\n" ++ @embedFile("devenv/get-env.sh");

/// develop.cc:Common::ignoreVars.
pub const ignore_vars = [_][]const u8{
    "BASHOPTS",
    "HOME",
    "NIX_BUILD_TOP",
    "NIX_ENFORCE_PURITY",
    "NIX_LOG_FD",
    "NIX_REMOTE",
    "PPID",
    "SHELLOPTS",
    "SSL_CERT_FILE",
    "TEMP",
    "TEMPDIR",
    "TERM",
    "TMP",
    "TMPDIR",
    "TZ",
    "UID",
};

/// develop.cc:makeRcScript savedVars: prepended to, not overwritten.
const saved_vars = [_][]const u8{ "PATH", "XDG_DATA_DIRS" };

/// The store path of `get-env.sh` as a text path without references
/// (develop.cc: `addToStoreFromDump(..., Flat, Text, SHA256, {})`).
pub fn getEnvShPath() StorePath {
    var d: Diag = .init(std.heap.page_allocator);
    defer d.deinit();
    return path_mod.makeTextPath("get-env.sh", hash_mod.hashBytes(.sha256, get_env_sh), .{}, &d) catch
        unreachable; // a valid store path name
}

/// Mirrors develop.cc:getDerivationEnvironment up to `writeDerivation`: the same
/// inputs and nearly the same environment as `shell`, with `get-env.sh` as the only
/// argument, so the build dumps the environment instead of building. Output paths are
/// recomputed from the new name and arguments. Everything new goes into `arena`; the
/// result shares the strings of `shell`.
pub fn envDerivation(
    arena: Allocator,
    shell: *const Derivation,
    cache: *drv_mod.DrvHashCache,
    loader: drv_mod.Loader,
    d: *Diag,
) Error!Derivation {
    const builder = if (std.mem.lastIndexOfScalar(u8, shell.builder, '/')) |i| shell.builder[i + 1 ..] else shell.builder;
    if (!std.mem.eql(u8, builder, "bash"))
        return d.fail(error.Store, "'nix develop' only works on derivations that use 'bash' as their builder", .{});
    var drv = shell.*;
    drv.outputs = try arena.dupe(drv_mod.NamedOutput, shell.outputs);
    drv.env = .empty;
    try drv.env.appendSlice(arena, shell.env.items);

    const get_env = getEnvShPath();
    const arg = try std.fmt.allocPrint(arena, "{f}", .{&get_env});
    drv.args = try arena.dupe([]const u8, &.{arg});
    if (shell.structured_attrs) |sa| {
        if (try store_json.eraseKey(arena, sa, "outputChecks", d)) |erased| drv.structured_attrs = erased;
    } else for ([_][]const u8{
        "allowedReferences",
        "allowedRequisites",
        "disallowedReferences",
        "disallowedRequisites",
    }) |k| drv.envRemove(k);
    drv.name = try std.mem.concat(arena, u8, &.{ shell.name, "-env" });
    try drv.envSet(arena, "name", drv.name);

    const srcs = try arena.alloc(StorePath, shell.input_srcs.len + 1);
    @memcpy(srcs[0..shell.input_srcs.len], shell.input_srcs);
    srcs[shell.input_srcs.len] = get_env;
    drv.input_srcs = path_mod.sortUnique(srcs);

    for (drv.outputs) |*o| switch (o.output) {
        .input_addressed, .fixed => {
            o.output = .deferred;
            try drv.envSet(arena, o.name, "");
        },
        else => {},
    };
    try drv_mod.finalizeInputAddressedOutputs(arena, &drv, cache, loader, d);
    return drv;
}

/// One key and its string, of a map sorted by key bytewise.
pub const Pair = struct { key: []const u8, value: []const u8 };

/// develop.cc:BuildEnvironment::Value.
pub const Value = union(enum) {
    string: struct { exported: bool, value: []const u8 },
    array: []const []const u8,
    /// Sorted by key, keys unique.
    associative: []const Pair,
};

pub const Var = struct { name: []const u8, value: Value };

/// develop.cc:BuildEnvironment: what `get-env.sh` dumped. Every list is sorted by
/// its key, bytewise, as the `std::map`s of Nix are.
pub const BuildEnvironment = struct {
    vars: []const Var = &.{},
    bash_functions: []const Pair = &.{},
    /// `.attrs.json` and `.attrs.sh` contents, for `__structuredAttrs` shells.
    structured_attrs: ?struct { json: []const u8, sh: []const u8 } = null,

    /// BuildEnvironment::fromJSON: variables of an unknown type are dropped.
    /// Everything is allocated in `arena`.
    pub fn fromJson(arena: Allocator, json: std.json.Value, d: *Diag) Error!BuildEnvironment {
        var res: BuildEnvironment = .{};
        const vars = objectOf(field(json, "variables")) orelse
            return d.fail(error.Protocol, "environment has no 'variables' object", .{});
        var out: std.ArrayList(Var) = try .initCapacity(arena, vars.count());
        var it = vars.iterator();
        while (it.next()) |e| {
            const info = e.value_ptr.*;
            const ty = try jsonStr(field(info, "type"), "variable type", d);
            const value = field(info, "value");
            const v: Value = if (std.mem.eql(u8, ty, "var") or std.mem.eql(u8, ty, "exported"))
                .{ .string = .{ .exported = ty[0] == 'e', .value = try jsonStr(value, "variable value", d) } }
            else if (std.mem.eql(u8, ty, "array")) blk: {
                if (value != .array) return d.fail(error.Protocol, "array variable is not a list", .{});
                const a = try arena.alloc([]const u8, value.array.items.len);
                for (value.array.items, a) |s, *x| x.* = try jsonStr(s, "array element", d);
                break :blk .{ .array = a };
            } else if (std.mem.eql(u8, ty, "associative")) blk: {
                const o = objectOf(value) orelse
                    return d.fail(error.Protocol, "associative variable is not an object", .{});
                break :blk .{ .associative = try stringMap(arena, o, "associative value", d) };
            } else continue;
            out.appendAssumeCapacity(.{ .name = e.key_ptr.*, .value = v });
        }
        std.mem.sort(Var, out.items, {}, struct {
            fn lt(_: void, a: Var, b: Var) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lt);
        res.vars = out.items;
        const funs = objectOf(field(json, "bashFunctions")) orelse
            return d.fail(error.Protocol, "environment has no 'bashFunctions' object", .{});
        res.bash_functions = try stringMap(arena, funs, "function body", d);
        if (json == .object) if (json.object.get("structuredAttrs")) |sa| {
            res.structured_attrs = .{
                .json = try jsonStr(field(sa, ".attrs.json"), ".attrs.json", d),
                .sh = try jsonStr(field(sa, ".attrs.sh"), ".attrs.sh", d),
            };
        };
        return res;
    }

    /// The file `get-env.sh` wrote, parsed into `arena`.
    pub fn parse(arena: Allocator, bytes: []const u8, d: *Diag) Error!BuildEnvironment {
        const json = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{
            .duplicate_field_behavior = .use_last,
            .parse_numbers = false,
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return d.fail(error.Protocol, "environment file is not valid JSON: {t}", .{e}),
        };
        return fromJson(arena, json, d);
    }

    /// BuildEnvironment::toJSON, written compact as Rust iets writes it. Keys sort
    /// bytewise, as nlohmann's `std::map` does.
    pub fn writeJson(env: *const BuildEnvironment, w: *Writer) Writer.Error!void {
        try w.writeAll("{\"bashFunctions\":");
        try writeStringMap(w, env.bash_functions);
        if (env.structured_attrs) |sa| {
            try w.writeAll(",\"structuredAttrs\":{\".attrs.json\":");
            try text_.writeJsonStringRaw(w, sa.json);
            try w.writeAll(",\".attrs.sh\":");
            try text_.writeJsonStringRaw(w, sa.sh);
            try w.writeByte('}');
        }
        try w.writeAll(",\"variables\":{");
        for (env.vars, 0..) |v, i| {
            if (i > 0) try w.writeByte(',');
            try text_.writeJsonStringRaw(w, v.name);
            try w.writeAll(":{\"type\":");
            switch (v.value) {
                .string => |s| {
                    try w.writeAll(if (s.exported) "\"exported\"" else "\"var\"");
                    try w.writeAll(",\"value\":");
                    try text_.writeJsonStringRaw(w, s.value);
                },
                .array => |a| {
                    try w.writeAll("\"array\",\"value\":[");
                    for (a, 0..) |s, j| {
                        if (j > 0) try w.writeByte(',');
                        try text_.writeJsonStringRaw(w, s);
                    }
                    try w.writeByte(']');
                },
                .associative => |m| {
                    try w.writeAll("\"associative\",\"value\":");
                    try writeStringMap(w, m);
                },
            }
            try w.writeByte('}');
        }
        try w.writeAll("}}");
    }

    /// BuildEnvironment::toBash.
    pub fn writeBash(env: *const BuildEnvironment, w: *Writer, ignore: []const []const u8) Writer.Error!void {
        outer: for (env.vars) |v| {
            for (ignore) |n| if (std.mem.eql(u8, n, v.name)) continue :outer;
            switch (v.value) {
                .string => |s| {
                    try w.print("{s}=", .{v.name});
                    try writeShellArgAlways(w, s.value);
                    try w.writeByte('\n');
                    if (s.exported) try w.print("export {s}\n", .{v.name});
                },
                .array => |a| {
                    try w.print("declare -a {s}=(", .{v.name});
                    for (a) |s| {
                        try writeShellArgAlways(w, s);
                        try w.writeByte(' ');
                    }
                    try w.writeAll(")\n");
                },
                .associative => |m| {
                    try w.print("declare -A {s}=(", .{v.name});
                    for (m) |p| {
                        try w.writeByte('[');
                        try writeShellArgAlways(w, p.key);
                        try w.writeAll("]=");
                        try writeShellArgAlways(w, p.value);
                        try w.writeByte(' ');
                    }
                    try w.writeAll(")\n");
                },
            }
        }
        for (env.bash_functions) |f| try w.print("{s} ()\n{{\n{s}}}\n", .{ f.key, f.value });
    }

    pub fn get(env: *const BuildEnvironment, name: []const u8) ?Value {
        const i = std.sort.binarySearch(Var, env.vars, name, struct {
            fn cmp(k: []const u8, v: Var) std.math.Order {
                return std.mem.order(u8, k, v.name);
            }
        }.cmp) orelse return null;
        return env.vars[i].value;
    }

    fn getString(env: *const BuildEnvironment, name: []const u8, d: *Diag) Error![]const u8 {
        return switch (env.get(name) orelse
            return d.fail(error.Protocol, "environment has no variable '{s}'", .{name})) {
            .string => |s| s.value,
            else => d.fail(error.Protocol, "bash variable '{s}' is not a string", .{name}),
        };
    }
};

/// `v[name]`, leniently: null for a missing key or a non-object.
fn field(v: std.json.Value, name: []const u8) std.json.Value {
    return if (v == .object) v.object.get(name) orelse .null else .null;
}

fn objectOf(v: std.json.Value) ?std.json.ObjectMap {
    return if (v == .object) v.object else null;
}

fn jsonStr(v: std.json.Value, comptime what: []const u8, d: *Diag) Error![]const u8 {
    return if (v == .string) v.string else d.fail(error.Protocol, what ++ " is not a string", .{});
}

fn stringMap(arena: Allocator, o: std.json.ObjectMap, comptime what: []const u8, d: *Diag) Error![]const Pair {
    const out = try arena.alloc(Pair, o.count());
    var it = o.iterator();
    var i: usize = 0;
    while (it.next()) |e| : (i += 1) out[i] = .{ .key = e.key_ptr.*, .value = try jsonStr(e.value_ptr.*, what, d) };
    std.mem.sort(Pair, out, {}, pairLessThan);
    return out;
}

fn pairLessThan(_: void, a: Pair, b: Pair) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn writeStringMap(w: *Writer, m: []const Pair) Writer.Error!void {
    try w.writeByte('{');
    for (m, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try text_.writeJsonStringRaw(w, p.key);
        try w.writeByte(':');
        try text_.writeJsonStringRaw(w, p.value);
    }
    try w.writeByte('}');
}

/// util.cc:escapeShellArgAlways.
pub fn writeShellArgAlways(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('\'');
    var it = std.mem.splitScalar(u8, s, '\'');
    try w.writeAll(it.first());
    while (it.next()) |part| {
        try w.writeAll("'\\''");
        try w.writeAll(part);
    }
    try w.writeByte('\'');
}

/// util.cc:escapeShellArgAlways, allocated with `gpa`.
pub fn escapeShellArgAlways(gpa: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: Writer.Allocating = try .initCapacity(gpa, s.len + 2);
    errdefer out.deinit();
    writeShellArgAlways(&out.writer, s) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// util.cc:rewriteStrings: every rewrite, in key order, applied to every occurrence,
/// left to right and never inside text a rewrite put in. `rewrites` is sorted by
/// key with keys unique. Returns `s` itself, or a new string from `gpa` that
/// replaces it (`s` is then freed).
pub fn rewriteStrings(gpa: Allocator, s: []u8, rewrites: []const Pair) Allocator.Error![]u8 {
    var cur = s;
    for (rewrites) |r| {
        if (r.key.len == 0 or std.mem.eql(u8, r.key, r.value)) continue;
        if (std.mem.indexOf(u8, cur, r.key) == null) continue;
        const next = try gpa.alloc(u8, std.mem.replacementSize(u8, cur, r.key, r.value));
        _ = std.mem.replace(u8, cur, r.key, r.value, next);
        gpa.free(cur);
        cur = next;
    }
    return cur;
}

/// The rewrites of `makeRcScript`: a `std::map`, so sorted by key, the last of two
/// equal keys kept.
const Rewrites = struct {
    list: std.ArrayList(Pair) = .empty,

    fn put(r: *Rewrites, arena: Allocator, from: []const u8, to: []const u8) Allocator.Error!void {
        try r.list.append(arena, .{ .key = from, .value = to });
    }

    fn sorted(r: *Rewrites) []const Pair {
        const items = r.list.items;
        // stable, so of two equal keys the later one stays later and is kept
        std.mem.sort(Pair, items, {}, pairLessThan);
        var n: usize = 0;
        for (items) |p| {
            if (n > 0 and std.mem.eql(u8, items[n - 1].key, p.key)) {
                items[n - 1] = p;
                continue;
            }
            items[n] = p;
            n += 1;
        }
        return items[0..n];
    }
};

/// The script `makeRcScript` prints, and the files it wrote for a `__structuredAttrs`
/// shell, so a cache hit can check they still exist.
pub const RcScript = struct {
    script: []u8,
    files: []const []const u8,
};

/// Mirrors develop.cc:Common::makeRcScript. `outputs_dir` is `<cwd>/outputs` in Nix;
/// `attrs_dir` receives `.attrs.sh` and `.attrs.json` for a structured-attrs shell (Nix
/// writes them to a temporary directory it deletes on exit; here they must outlive the
/// process). The script comes from `gpa`; the file list and scratch go into `arena`.
pub fn makeRcScript(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    env: *const BuildEnvironment,
    attrs_dir: []const u8,
    outputs_dir: []const u8,
    d: *Diag,
) Error!RcScript {
    var out: Writer.Allocating = try .initCapacity(gpa, 64 << 10);
    defer out.deinit();
    writeRc(&out.writer, env) catch return error.OutOfMemory;

    var rewrites: Rewrites = .{};
    const outputs = env.get("outputs") orelse
        return d.fail(error.Protocol, "environment has no 'outputs' variable", .{});
    switch (outputs) {
        .associative => |m| for (m) |p| try rewrites.put(arena, p.value, try outputPath(arena, outputs_dir, p.key)),
        .string => |s| {
            var it = std.mem.tokenizeAny(u8, s.value, " \t\n\r");
            while (it.next()) |name| try rewrites.put(arena, try env.getString(name, d), try outputPath(arena, outputs_dir, name));
        },
        .array => |a| for (a) |name| try rewrites.put(arena, try env.getString(name, d), try outputPath(arena, outputs_dir, name)),
    }

    var files: std.ArrayList([]const u8) = .empty;
    if (env.structured_attrs) |sa| {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(io, attrs_dir) catch |e|
            return d.fail(error.Io, "cannot create '{s}': {s}", .{ attrs_dir, errors.ioText(e) });
        const parts = [_]struct { ext: []const u8, @"var": []const u8, content: []const u8 }{
            .{ .ext = "sh", .@"var" = "NIX_ATTRS_SH_FILE", .content = sa.sh },
            .{ .ext = "json", .@"var" = "NIX_ATTRS_JSON_FILE", .content = sa.json },
        };
        for (parts) |p| {
            const target = try std.fmt.allocPrint(arena, "{s}/.attrs.{s}", .{ attrs_dir, p.ext });
            writeFile(arena, io, target, p.content) catch |e|
                return d.fail(error.Io, "cannot write '{s}': {s}", .{ target, errors.ioText(e) });
            try rewrites.put(arena, try env.getString(p.@"var", d), target);
            try files.append(arena, target);
        }
    }
    const script = try out.toOwnedSlice();
    return .{ .script = try rewriteStrings(gpa, script, rewrites.sorted()), .files = files.items };
}

fn writeRc(w: *Writer, env: *const BuildEnvironment) Writer.Error!void {
    try w.writeAll("unset shellHook\n");
    for (saved_vars) |v| try w.print("{s}=${{{s}:-}}\nnix_saved_{s}=\"${s}\"\n", .{ v, v, v, v });
    try env.writeBash(w, &ignore_vars);
    for (saved_vars) |v| try w.print("{s}=\"${s}${{nix_saved_{s}:+:$nix_saved_{s}}}\"\n", .{ v, v, v, v });
    try w.writeAll("export NIX_BUILD_TOP=\"$(mktemp -d -t nix-shell.XXXXXX)\"\n");
    for ([_][]const u8{ "TMP", "TMPDIR", "TEMP", "TEMPDIR" }) |v| try w.print("export {s}=\"$NIX_BUILD_TOP\"\n", .{v});
    try w.writeAll("eval \"${shellHook:-}\"\n");
}

/// `outputs_dir.join(name)`.
fn outputPath(arena: Allocator, outputs_dir: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, name, "/")) return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ outputs_dir, name });
}

/// A temporary file beside `path`, renamed over it.
fn writeFile(arena: Allocator, io: Io, path: []const u8, content: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse ".";
    const tmp = try std.fmt.allocPrint(arena, "{s}/.{s}.{d}.tmp", .{ dir, std.fs.path.basename(path), sys.pid() });
    const cwd = Io.Dir.cwd();
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = content });
    Io.Dir.rename(cwd, tmp, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp) catch {};
        return e;
    };
}

/// What a `print-dev-env` cache entry stores: the env output, the files the printed bytes
/// refer to, and the bytes themselves.
pub const CachedResult = struct {
    out_path: []const u8,
    files: []const []const u8,
    bytes: []const u8,

    pub fn write(r: *const CachedResult, w: *Writer) Writer.Error!void {
        try w.writeAll(r.out_path);
        try w.writeByte('\n');
        for (r.files) |f| {
            try w.writeAll(f);
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
        try w.writeAll(r.bytes);
    }

    pub fn encode(r: *const CachedResult, gpa: Allocator) Allocator.Error![]u8 {
        var out: Writer.Allocating = try .initCapacity(gpa, r.bytes.len + 256);
        errdefer out.deinit();
        r.write(&out.writer) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }

    /// The entry `encode` wrote; its slices point into `b`, the file list into
    /// `arena`. Null when it is not one.
    pub fn decode(arena: Allocator, b: []const u8) Allocator.Error!?CachedResult {
        var lines: std.ArrayList([]const u8) = .empty;
        var rest = b;
        while (true) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
            const line = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (line.len == 0) break;
            try lines.append(arena, line);
        }
        if (lines.items.len == 0) return null;
        if (!std.unicode.utf8ValidateSlice(lines.items[0])) return null;
        return .{ .out_path = lines.items[0], .files = lines.items[1..], .bytes = rest };
    }
};

const testing = std.testing;

fn parseJson(arena: Allocator, text: []const u8) !BuildEnvironment {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    return BuildEnvironment.parse(arena, text, &d);
}

// Nix 2.34.8 added this file with `nix print-dev-env`; the path is in every `-env.drv`
// it wrote (`grep get-env.sh /nix/store/*-env.drv`).
test "get-env.sh store path matches nix" {
    const p = getEnvShPath();
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/nix/store/hyhh9rhzxhzmfspllmpf75xzkzns109r-get-env.sh", try std.fmt.bufPrint(&buf, "{f}", .{&p}));
}

test "non-bash builder is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var cache: drv_mod.DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    var sl: drv_mod.StoreLoader = .{ .io = testing.io };
    const drv: Derivation = .{ .name = "x", .builder = "/bin/sh" };
    try testing.expectError(error.Store, envDerivation(arena.allocator(), &drv, &cache, sl.loader(), &d));
    try testing.expectEqualStrings("'nix develop' only works on derivations that use 'bash' as their builder", d.message());
}

// The `-env.drv` that `nix print-dev-env` (2.34.9) wrote for each shell `.drv` of
// `testdata/`: a plain shell with two outputs and `allowedReferences`, a structured-attrs
// one with `outputChecks`, a fixed-output one. None has an input derivation, so the hash
// modulo needs nothing from the store.
test "env derivation matches nix" {
    const cases = [_][2][]const u8{
        .{ "f4a4zdglk3lybl8sp672c5ai5fc713l2-iets-devenv-plain", "gr0b4q58bmwaj6vrv9vqf934m1dqrdic-iets-devenv-plain-env" },
        .{ "492fil1q4v6ap4wcxq34asp2lyjvqpyh-iets-devenv-sa", "1vw3hdf8da3dblndb5zbnf64asbzghd0-iets-devenv-sa-env" },
        .{ "3cda572lzjs1cgwnh5rdm341ii7xh061-iets-devenv-fixed", "zmi0yyvdhjk1gw7zv8fpl0l191yiblpr-iets-devenv-fixed-env" },
    };
    inline for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var d: Diag = .init(testing.allocator);
        defer d.deinit();
        var cache: drv_mod.DrvHashCache = .init(testing.allocator);
        defer cache.deinit();
        var sl: drv_mod.StoreLoader = .{ .io = testing.io };
        const shell_path = try StorePath.fromBaseName(c[0] ++ ".drv", &d);
        const shell = try Derivation.parse(a, @embedFile("devenv/testdata/" ++ c[0] ++ ".drv"), try Derivation.nameFromPath(&shell_path, &d), &d);
        const env = try envDerivation(a, &shell, &cache, sl.loader(), &d);
        const text = try env.unparseAlloc(a, .{}, &d);
        try testing.expectEqualStrings(@embedFile("devenv/testdata/" ++ c[1] ++ ".drv"), text);
        const p = try env.drvPathFor(a, text, &d);
        try testing.expectEqualStrings(c[1] ++ ".drv", p.baseName());
    }
}

test "output checks are erased only when present" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const got = (try store_json.eraseKey(testing.allocator, "{\"b\":1,\"outputChecks\":{\"out\":{}},\"a\":\"x\"}", "outputChecks", &d)).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{\"a\":\"x\",\"b\":1}", got);
    try testing.expect(try store_json.eraseKey(testing.allocator, "{\"z\":1,\"a\":[1,2]}", "outputChecks", &d) == null);
}

test "shell escaping" {
    const cases = [_][2][]const u8{ .{ "", "''" }, .{ "a b", "'a b'" }, .{ "it's", "'it'\\''s'" }, .{ "''", "''\\'''\\'''" } };
    for (cases) |c| {
        const got = try escapeShellArgAlways(testing.allocator, c[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "rewrites apply in map order to every occurrence" {
    const r = [_]Pair{
        .{ .key = "/nix/store/x-out", .value = "/w/outputs/out" },
        .{ .key = "same", .value = "same" },
    };
    const s = try testing.allocator.dupe(u8, "a=/nix/store/x-out:/nix/store/x-out same");
    const got = try rewriteStrings(testing.allocator, s, &r);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a=/w/outputs/out:/w/outputs/out same", got);
    // a replacement is never searched again
    const r2 = [_]Pair{.{ .key = "a", .value = "aa" }};
    const got2 = try rewriteStrings(testing.allocator, try testing.allocator.dupe(u8, "aba"), &r2);
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings("aabaa", got2);
}

test "json round trip and bash forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try parseJson(a,
        \\{
        \\  "bashFunctions": {"f": " \n    echo hi\n"},
        \\  "variables": {
        \\    "A": {"type": "exported", "value": "it's"},
        \\    "B": {"type": "var", "value": "b"},
        \\    "L": {"type": "array", "value": ["x", "y z"]},
        \\    "M": {"type": "associative", "value": {"k": "v", "a": "b"}},
        \\    "TERM": {"type": "exported", "value": "dumb"},
        \\    "U": {"type": "unknown"}
        \\  }
        \\}
    );
    try testing.expect(env.get("U") == null);
    var json: Writer.Allocating = .init(a);
    try env.writeJson(&json.writer);
    try testing.expectEqualStrings(
        \\{"bashFunctions":{"f":" \n    echo hi\n"},"variables":{"A":{"type":"exported","value":"it's"},"B":{"type":"var","value":"b"},"L":{"type":"array","value":["x","y z"]},"M":{"type":"associative","value":{"a":"b","k":"v"}},"TERM":{"type":"exported","value":"dumb"}}}
    , json.written());
    const again = try parseJson(a, json.written());
    var json2: Writer.Allocating = .init(a);
    try again.writeJson(&json2.writer);
    try testing.expectEqualStrings(json.written(), json2.written());

    var bash: Writer.Allocating = .init(a);
    try env.writeBash(&bash.writer, &ignore_vars);
    try testing.expectEqualStrings("A='it'\\''s'\nexport A\nB='b'\ndeclare -a L=('x' 'y z' )\ndeclare -A M=(['a']='b' ['k']='v' )\nf ()\n{\n \n    echo hi\n}\n", bash.written());
}

test "json strings are escaped as serde_json escapes them" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try text_.writeJsonStringRaw(&out.writer, "a\"\\\x08\x0c\n\r\t\x01\x1f\x7f/é");
    try testing.expectEqualStrings("\"a\\\"\\\\\\b\\f\\n\\r\\t\\u0001\\u001f\x7f/é\"", out.written());
}

test "malformed environments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "{", "environment file is not valid JSON: " },
        .{ "{\"bashFunctions\":{}}", "environment has no 'variables' object" },
        .{ "{\"variables\":{}}", "environment has no 'bashFunctions' object" },
        .{ "{\"variables\":{\"x\":{\"type\":1}},\"bashFunctions\":{}}", "variable type is not a string" },
        .{ "{\"variables\":{\"x\":{\"type\":\"array\",\"value\":{}}},\"bashFunctions\":{}}", "array variable is not a list" },
        .{ "{\"variables\":{},\"bashFunctions\":{},\"structuredAttrs\":null}", ".attrs.json is not a string" },
    };
    for (cases) |c| {
        try testing.expectError(error.Protocol, BuildEnvironment.parse(a, c[0], &d));
        try testing.expect(std.mem.startsWith(u8, d.message(), c[1]));
    }
}

test "rc script rewrites outputs and writes attrs" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const env = try parseJson(a,
        \\{
        \\  "bashFunctions": {},
        \\  "variables": {
        \\    "outputs": {"type": "var", "value": "out dev"},
        \\    "out": {"type": "exported", "value": "/nix/store/a-x-env"},
        \\    "dev": {"type": "exported", "value": "/nix/store/b-x-env-dev"},
        \\    "NIX_LDFLAGS": {"type": "exported", "value": "-rpath /nix/store/a-x-env/lib"},
        \\    "NIX_ATTRS_SH_FILE": {"type": "exported", "value": "/build/.attrs.sh"},
        \\    "NIX_ATTRS_JSON_FILE": {"type": "exported", "value": "/build/.attrs.json"}
        \\  },
        \\  "structuredAttrs": {".attrs.sh": "declare x=1\n", ".attrs.json": "{}"}
        \\}
    );
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const attrs = try std.fmt.allocPrint(a, "{s}/attrs", .{base});
    const rc = try makeRcScript(testing.allocator, a, testing.io, &env, attrs, "/w/outputs", &d);
    defer testing.allocator.free(rc.script);
    try testing.expect(std.mem.startsWith(u8, rc.script, "unset shellHook\nPATH=${PATH:-}\nnix_saved_PATH=\"$PATH\"\nXDG_DATA_DIRS=${XDG_DATA_DIRS:-}\nnix_saved_XDG_DATA_DIRS=\"$XDG_DATA_DIRS\"\n"));
    try testing.expect(std.mem.endsWith(u8, rc.script, "PATH=\"$PATH${nix_saved_PATH:+:$nix_saved_PATH}\"\nXDG_DATA_DIRS=\"$XDG_DATA_DIRS${nix_saved_XDG_DATA_DIRS:+:$nix_saved_XDG_DATA_DIRS}\"\nexport NIX_BUILD_TOP=\"$(mktemp -d -t nix-shell.XXXXXX)\"\nexport TMP=\"$NIX_BUILD_TOP\"\nexport TMPDIR=\"$NIX_BUILD_TOP\"\nexport TEMP=\"$NIX_BUILD_TOP\"\nexport TEMPDIR=\"$NIX_BUILD_TOP\"\neval \"${shellHook:-}\"\n"));
    try testing.expect(std.mem.indexOf(u8, rc.script, "NIX_LDFLAGS='-rpath /w/outputs/out/lib'\n") != null);
    try testing.expect(std.mem.indexOf(u8, rc.script, "dev='/w/outputs/dev'\n") != null);
    const sh = try std.fmt.allocPrint(a, "{s}/.attrs.sh", .{attrs});
    const got = try Io.Dir.cwd().readFileAlloc(testing.io, sh, a, .unlimited);
    try testing.expectEqualStrings("declare x=1\n", got);
    try testing.expect(std.mem.indexOf(u8, rc.script, try std.fmt.allocPrint(a, "NIX_ATTRS_SH_FILE='{s}'\n", .{sh})) != null);
    try testing.expectEqual(2, rc.files.len);
}

test "cached result round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: CachedResult = .{ .out_path = "/nix/store/x-env", .files = &.{"/a/.attrs.sh"}, .bytes = "x=1\n\nexport x\n" };
    const dec = (try CachedResult.decode(a, try r.encode(a))).?;
    try testing.expectEqualStrings(r.out_path, dec.out_path);
    try testing.expectEqual(1, dec.files.len);
    try testing.expectEqualStrings(r.files[0], dec.files[0]);
    try testing.expectEqualStrings(r.bytes, dec.bytes);
    r.files = &.{};
    try testing.expectEqual(0, (try CachedResult.decode(a, try r.encode(a))).?.files.len);
    try testing.expect(try CachedResult.decode(a, "") == null);
}
