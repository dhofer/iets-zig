//! Derivations: the ATerm `.drv` format, output paths, and the hash modulo
//! fixed outputs that input-addressed paths come from. Mirrors libstore's
//! derivations.cc.

const std = @import("std");
const Scratch = @import("../Scratch.zig");
const bytes = @import("../bytes.zig");
const Io = std.Io;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("hash.zig");
const Hash = hash_mod.Hash;
const path_mod = @import("path.zig");
const StorePath = path_mod.StorePath;
const IngestionMethod = path_mod.IngestionMethod;
const json = @import("json.zig");

pub const Error = error{ BadDerivation, BadStorePath, BadHash, BadJson, OutOfMemory };

/// The env var that carries structured attrs (parsed-derivations.hh:StructuredAttrs::envVarName).
pub const structured_attrs_env = "__json";

/// Mirrors derivations.hh:DerivationOutput (Impure is not supported).
pub const Output = union(enum) {
    input_addressed: StorePath,
    fixed: struct { method: IngestionMethod, hash: Hash },
    deferred,
    ca_floating: struct { method: IngestionMethod, algo: hash_mod.Algo },
};

pub const NamedOutput = struct { name: []const u8, output: Output };

/// Mirrors derived-path-map.hh:DerivedPathMap<StringSet>::ChildNode, the value of
/// `input_drvs`. `outputs` are the outputs of that `.drv` this derivation uses,
/// sorted and unique. `children` names the outputs that are themselves `.drv`s,
/// sorted by name, and what is used of them: a dependency on the output of a
/// dynamic derivation. It is empty for every derivation that has none, and
/// then the traditional `Derive(` ATerm is written.
pub const InputNode = struct {
    outputs: []const []const u8 = &.{},
    children: []const Child = &.{},

    pub const Child = struct { name: []const u8, node: InputNode };

    pub fn isDynamic(n: InputNode) bool {
        return n.children.len > 0;
    }
};

pub const InputDrv = struct { path: StorePath, node: InputNode };

pub const EnvVar = struct { key: []const u8, value: []const u8 };

/// Mirrors derivations.hh:Derivation. Every list is sorted by its key, bytewise,
/// without duplicates, as Nix's maps and sets are. A parsed derivation borrows
/// its strings from the text it was parsed from and from the arena.
pub const Derivation = struct {
    name: []const u8,
    outputs: []NamedOutput = &.{},
    input_srcs: []const StorePath = &.{},
    input_drvs: []const InputDrv = &.{},
    platform: []const u8 = "",
    builder: []const u8 = "",
    args: []const []const u8 = &.{},
    env: std.ArrayList(EnvVar) = .empty,
    structured_attrs: ?[]const u8 = null,

    pub fn output(drv: *const Derivation, name: []const u8) ?*NamedOutput {
        const i = std.sort.binarySearch(NamedOutput, drv.outputs, name, struct {
            fn cmp(k: []const u8, o: NamedOutput) std.math.Order {
                return std.mem.order(u8, k, o.name);
            }
        }.cmp) orelse return null;
        return &drv.outputs[i];
    }

    fn envIndex(drv: *const Derivation, key: []const u8) union(enum) { found: usize, insert: usize } {
        const items = drv.env.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, items[mid].key, key)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return .{ .found = mid },
            }
        }
        return .{ .insert = lo };
    }

    pub fn envGet(drv: *const Derivation, key: []const u8) ?[]const u8 {
        return switch (drv.envIndex(key)) {
            .found => |i| drv.env.items[i].value,
            .insert => null,
        };
    }

    /// Inserts or replaces `key`. The strings are not copied.
    pub fn envSet(drv: *Derivation, gpa: Allocator, key: []const u8, value: []const u8) Allocator.Error!void {
        switch (drv.envIndex(key)) {
            .found => |i| drv.env.items[i].value = value,
            .insert => |i| try drv.env.insert(gpa, i, .{ .key = key, .value = value }),
        }
    }

    pub fn envRemove(drv: *Derivation, key: []const u8) void {
        switch (drv.envIndex(key)) {
            .found => |i| _ = drv.env.orderedRemove(i),
            .insert => {},
        }
    }

    /// Mirrors derivations.cc:DerivationType::isFixed: every output is fixed.
    pub fn isFixed(drv: *const Derivation) bool {
        if (drv.outputs.len == 0) return false;
        for (drv.outputs) |o| if (o.output != .fixed) return false;
        return true;
    }

    /// Mirrors derivations.cc:DerivationOutput::CAFixed::path for output `output_name`.
    pub fn fixedOutputPath(drv: *const Derivation, output_name: []const u8, d: *Diag) Error!StorePath {
        const o = drv.output(output_name) orelse
            return d.fail(error.BadDerivation, "no output '{s}'", .{output_name});
        return switch (o.output) {
            .fixed => |f| path_mod.makeFixedOutputPathFor(f.method, f.hash, drv.name, output_name, d),
            else => d.fail(error.BadDerivation, "output '{s}' is not fixed", .{output_name}),
        };
    }

    /// Mirrors derivations.cc:DerivationOutput::path: the statically known path of
    /// output `output_name`, if any.
    pub fn outputPath(drv: *const Derivation, output_name: []const u8, d: *Diag) Error!?StorePath {
        const o = drv.output(output_name) orelse return null;
        return switch (o.output) {
            .input_addressed => |p| p,
            .fixed => try drv.fixedOutputPath(output_name, d),
            .deferred, .ca_floating => null,
        };
    }

    /// Mirrors derivations.cc:Derivation::unparse(store, maskOutputs, actualInputs).
    pub fn writeAterm(drv: *const Derivation, w: *Writer, opts: UnparseOptions, d: *Diag) (Error || Writer.Error)!void {
        try drv.writeHead(w, opts, d);
        try drv.writeTail(w, opts.mask_outputs, d);
    }

    /// `writeAterm` into memory from `gpa`.
    pub fn unparseAlloc(drv: *const Derivation, gpa: Allocator, opts: UnparseOptions, d: *Diag) Error![]u8 {
        var out: Writer.Allocating = try .initCapacity(gpa, 4096);
        errdefer out.deinit();
        drv.writeAterm(&out.writer, opts, d) catch |e| return switch (e) {
            error.WriteFailed => error.OutOfMemory,
            else => |x| x,
        };
        return out.toOwnedSlice();
    }

    /// The sha256 of `writeAterm`, streamed: the ATerm is never held whole.
    pub fn hashAterm(drv: *const Derivation, opts: UnparseOptions, d: *Diag) Error!Hash {
        var hasher: hash_mod.Hasher = .init(.sha256);
        var buf: [4096]u8 = undefined;
        var hw = hasher.writer(&buf);
        drv.writeAterm(&hw.interface, opts, d) catch |e| return switch (e) {
            error.WriteFailed => unreachable,
            else => |x| x,
        };
        hw.interface.flush() catch unreachable;
        return hasher.finish();
    }

    fn writeHead(drv: *const Derivation, w: *Writer, opts: UnparseOptions, d: *Diag) (Error || Writer.Error)!void {
        // derivations.cc:hasDynamicDrvDep, over this derivation's own inputs and
        // never over `actual_inputs`, whose nodes the hash-modulo form flattens
        const dynamic = for (drv.input_drvs) |i| {
            if (i.node.isDynamic()) break true;
        } else false;
        try w.writeAll(if (dynamic) "DrvWithVersion(\"xp-dyn-drv\",[" else "Derive([");
        for (drv.outputs, 0..) |o, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("(\"{s}\",", .{o.name});
            switch (o.output) {
                .input_addressed => |p| {
                    if (opts.mask_outputs) try w.writeAll("\"\"") else try writeStorePath(w, p);
                    try w.writeAll(",\"\",\"\"");
                },
                .fixed => |f| {
                    if (opts.mask_outputs) try w.writeAll("\"\"") else try writeStorePath(w, try drv.fixedOutputPath(o.name, d));
                    try w.writeByte(',');
                    try writeMethodAlgo(w, f.method, f.hash.algo);
                    try w.writeAll(",\"");
                    try hash_mod.writeBase16(w, f.hash.bytes());
                    try w.writeByte('"');
                },
                .ca_floating => |f| {
                    try w.writeAll("\"\",");
                    try writeMethodAlgo(w, f.method, f.algo);
                    try w.writeAll(",\"\"");
                },
                .deferred => try w.writeAll("\"\",\"\",\"\""),
            }
            try w.writeByte(')');
        }
        try w.writeAll("],[");
        if (opts.actual_inputs) |inputs| {
            for (inputs, 0..) |in, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("(\"{s}\"", .{&in.hex});
                try writeNode(w, .{ .outputs = in.outputs });
                try w.writeByte(')');
            }
        } else {
            for (drv.input_drvs, 0..) |in, i| {
                if (i > 0) try w.writeByte(',');
                try w.writeByte('(');
                try writeStorePath(w, in.path);
                try writeNode(w, in.node);
                try w.writeByte(')');
            }
        }
        try w.writeAll("],");
    }

    /// The ATerm from the input sources on.
    fn writeTail(drv: *const Derivation, w: *Writer, mask_outputs: bool, d: *Diag) (Error || Writer.Error)!void {
        try w.writeByte('[');
        for (drv.input_srcs, 0..) |p, i| {
            if (i > 0) try w.writeByte(',');
            try writeStorePath(w, p);
        }
        try w.print("],\"{s}\",", .{drv.platform});
        try writeString(w, drv.builder);
        try w.writeAll(",[");
        for (drv.args, 0..) |a, i| {
            if (i > 0) try w.writeByte(',');
            try writeString(w, a);
        }
        try w.writeAll("],[");
        var first = true;
        var pending_json = drv.structured_attrs;
        for (drv.env.items) |e| {
            // parsed-derivations.cc:StructuredAttrs::checkKeyNotInUse
            if (std.mem.eql(u8, e.key, structured_attrs_env))
                return d.fail(error.BadDerivation, "Cannot have an environment variable named '{s}'. This key is reserved for encoding structured attrs", .{structured_attrs_env});
            if (pending_json) |j| if (std.mem.order(u8, e.key, structured_attrs_env) == .gt) {
                try drv.writeEnv(w, &first, structured_attrs_env, j, mask_outputs);
                pending_json = null;
            };
            try drv.writeEnv(w, &first, e.key, e.value, mask_outputs);
        }
        if (pending_json) |j| try drv.writeEnv(w, &first, structured_attrs_env, j, mask_outputs);
        try w.writeAll("])");
    }

    fn writeEnv(drv: *const Derivation, w: *Writer, first: *bool, k: []const u8, v: []const u8, mask_outputs: bool) Writer.Error!void {
        if (!first.*) try w.writeByte(',');
        first.* = false;
        try w.writeByte('(');
        try writeString(w, k);
        try w.writeByte(',');
        try writeString(w, if (mask_outputs and drv.output(k) != null) "" else v);
        try w.writeByte(')');
    }

    /// Mirrors derivations.cc:parseDerivation, both the traditional `Derive(...)`
    /// form and `DrvWithVersion("xp-dyn-drv",...)`. Strings without escapes are
    /// slices of `text`; everything else, `name` included, is allocated in `arena`.
    pub fn parse(arena: Allocator, text: []const u8, name: []const u8, d: *Diag) Error!Derivation {
        var p: Parser = .{ .s = text, .arena = arena, .d = d };
        var drv: Derivation = .{ .name = try arena.dupe(u8, name) };
        const dynamic = std.mem.startsWith(u8, text, "DrvWithVersion(");
        if (dynamic) {
            try p.expect("DrvWithVersion(");
            const v = try p.string();
            if (!std.mem.eql(u8, v, "xp-dyn-drv"))
                return d.fail(error.BadDerivation, "derivation '{s}', ATerm format version '{s}' is not supported", .{ name, v });
            try p.expect(",[");
        } else try p.expect("Derive([");

        var outputs: std.ArrayList(NamedOutput) = .empty;
        while (!p.endOfList()) {
            try p.expect("(");
            const id = try p.string();
            try p.expect(",");
            const path = try p.string();
            try p.expect(",");
            const algo = try p.string();
            try p.expect(",");
            const h = try p.string();
            try p.expect(")");
            try outputs.append(arena, .{ .name = id, .output = try parseOutput(path, algo, h, d) });
        }
        drv.outputs = sortKeepLast(NamedOutput, outputs.items, "name");

        try p.expect(",[");
        var inputs: std.ArrayList(InputDrv) = .empty;
        while (!p.endOfList()) {
            try p.expect("(");
            const path = try p.path();
            const node = try p.inputNode(dynamic);
            try p.expect(")");
            try inputs.append(arena, .{ .path = try StorePath.parse(path, d), .node = node });
        }
        drv.input_drvs = sortKeepLast(InputDrv, inputs.items, "path");

        try p.expect(",");
        const srcs = try p.stringList();
        const src_paths = try arena.alloc(StorePath, srcs.len);
        for (srcs, src_paths) |s, *sp| {
            if (!std.mem.startsWith(u8, s, "/")) return d.fail(error.BadDerivation, "bad path '{s}' in derivation", .{s});
            sp.* = try StorePath.parse(s, d);
        }
        drv.input_srcs = path_mod.sortUnique(src_paths);

        try p.expect(",");
        drv.platform = try p.string();
        try p.expect(",");
        drv.builder = try p.string();
        try p.expect(",[");
        var args: std.ArrayList([]const u8) = .empty;
        while (!p.endOfList()) try args.append(arena, try p.bytes());
        drv.args = args.items;
        try p.expect(",[");
        while (!p.endOfList()) {
            try p.expect("(");
            const k = try p.string();
            try p.expect(",");
            const v = try p.bytes();
            try p.expect(")");
            if (std.mem.eql(u8, k, structured_attrs_env)) {
                drv.structured_attrs = try json.normaliseStructuredAttrs(arena, v, d);
            } else try drv.env.append(arena, .{ .key = k, .value = v });
        }
        try p.expect(")");
        drv.env.items.len = sortKeepLast(EnvVar, drv.env.items, "key").len;
        return drv;
    }

    /// Mirrors derivations.cc:BasicDerivation::nameFromPath: strips `.drv` from
    /// the path name. The result points into `drv_path`.
    pub fn nameFromPath(drv_path: *const StorePath, d: *Diag) Error![]const u8 {
        const n = drv_path.name();
        if (!std.mem.endsWith(u8, n, path_mod.drv_extension))
            return d.fail(error.BadDerivation, "'{f}' is not a derivation path", .{drv_path});
        return n[0 .. n.len - path_mod.drv_extension.len];
    }

    /// The path of this derivation's `.drv` (derivations.cc:computeStorePath).
    /// `gpa` holds the reference list for the duration of the call.
    pub fn drvPath(drv: *const Derivation, gpa: Allocator, d: *Diag) Error!StorePath {
        return drv.drvPathFromHash(gpa, try drv.hashAterm(.{}, d), d);
    }

    /// `drvPath` for a caller that already holds `aterm`, the derivation's ATerm.
    pub fn drvPathFor(drv: *const Derivation, gpa: Allocator, aterm: []const u8, d: *Diag) Error!StorePath {
        return drv.drvPathFromHash(gpa, hash_mod.hashBytes(.sha256, aterm), d);
    }

    fn drvPathFromHash(drv: *const Derivation, gpa: Allocator, h: Hash, d: *Diag) Error!StorePath {
        const drv_paths = try gpa.alloc(StorePath, drv.input_drvs.len);
        defer gpa.free(drv_paths);
        for (drv.input_drvs, drv_paths) |in, *p| p.* = in.path;
        var buf: [path_mod.max_name_len + 1]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}" ++ path_mod.drv_extension, .{drv.name}) catch
            return d.fail(error.BadStorePath, "name '{s}.drv' must be no longer than {d} characters", .{ drv.name, path_mod.max_name_len });
        return path_mod.makeTextPath(name, h, .{ .a = drv.input_srcs, .b = drv_paths }, d);
    }
};

pub const UnparseOptions = struct {
    /// Blank the output paths and the env values named after outputs.
    mask_outputs: bool = false,
    /// Write these in place of `input_drvs`: the hash-modulo form.
    actual_inputs: ?[]const ModuloInput = null,
};

/// One input of the hash-modulo ATerm: the base16 hash modulo of an input
/// derivation, and the outputs of it that are used.
pub const ModuloInput = struct {
    hex: [64]u8,
    outputs: []const []const u8,
};

/// Stable sort by `field`, then of each run of equal keys the last is kept:
/// what inserting into a `std::map` one by one leaves.
fn sortKeepLast(comptime T: type, items: []T, comptime field: []const u8) []T {
    const S = struct {
        /// By pointer: a `StorePath` key holds its bytes.
        fn key(x: *const T) []const u8 {
            const k = &@field(x.*, field);
            return if (@TypeOf(k.*) == StorePath) k.baseName() else k.*;
        }
        fn lt(_: void, a: T, b: T) bool {
            return std.mem.lessThan(u8, key(&a), key(&b));
        }
    };
    std.mem.sort(T, items, {}, S.lt);
    var n: usize = 0;
    for (items) |*x| {
        if (n > 0 and std.mem.eql(u8, S.key(&items[n - 1]), S.key(x))) {
            items[n - 1] = x.*;
            continue;
        }
        items[n] = x.*;
        n += 1;
    }
    return items[0..n];
}

/// Mirrors derivations.cc:printString: an ATerm string with `\"`, `\\`, `\n`,
/// `\r`, `\t` escapes.
fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    try writeEscaped(w, s);
    try w.writeByte('"');
}

fn writeEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    var done: usize = 0;
    while (bytes.findAnyPos(s, done, "\"\\\n\r\t")) |i| {
        try w.writeAll(s[done..i]);
        try w.writeAll(switch (s[i]) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            else => "\\t",
        });
        done = i + 1;
    }
    try w.writeAll(s[done..]);
}

fn writeStorePath(w: *Writer, p: StorePath) Writer.Error!void {
    // A Windows directory holds backslashes, which a string escapes; a base
    // name holds none of the escaped characters (`checkName`)
    try w.writeByte('"');
    try writeEscaped(w, path_mod.store_dir);
    try w.print("/{s}\"", .{p.baseName()});
}

/// Mirrors content-address.cc:ContentAddress::printMethodAlgo, quoted.
fn writeMethodAlgo(w: *Writer, method: IngestionMethod, algo: hash_mod.Algo) Writer.Error!void {
    try w.print("\"{s}{s}\"", .{ method.prefix(), algo.name() });
}

fn writeNames(w: *Writer, names: []const []const u8) Writer.Error!void {
    try w.writeByte('[');
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\"", .{n});
    }
    try w.writeByte(']');
}

/// Mirrors derivations.cc:unparseDerivedPathMapNode, including the comma it writes.
fn writeNode(w: *Writer, node: InputNode) Writer.Error!void {
    try w.writeByte(',');
    if (!node.isDynamic()) return writeNames(w, node.outputs);
    try w.writeByte('(');
    try writeNames(w, node.outputs);
    try w.writeAll(",[");
    for (node.children, 0..) |c, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("(\"{s}\"", .{c.name});
        try writeNode(w, c.node);
        try w.writeByte(')');
    }
    try w.writeAll("])");
}

/// Mirrors derivations.cc:parseDerivationOutput(store, pathS, hashAlgoStr, hashS).
fn parseOutput(path: []const u8, hash_algo: []const u8, h: []const u8, d: *Diag) Error!Output {
    if (hash_algo.len == 0) {
        if (path.len == 0) return .deferred;
        return .{ .input_addressed = try StorePath.parse(path, d) };
    }
    var method: IngestionMethod = .flat;
    var algo_name = hash_algo;
    if (std.mem.startsWith(u8, hash_algo, "r:")) {
        method = .recursive;
        algo_name = hash_algo[2..];
    } else if (std.mem.startsWith(u8, hash_algo, "text:")) {
        method = .text;
        algo_name = hash_algo[5..];
    } else if (std.mem.startsWith(u8, hash_algo, "git:")) {
        return d.fail(error.BadDerivation, "unsupported output hash method '{s}'", .{hash_algo});
    }
    const algo = hash_mod.Algo.parse(algo_name) orelse
        return d.fail(error.BadDerivation, "unknown hash algorithm '{s}'", .{algo_name});
    if (std.mem.eql(u8, h, "impure")) return d.fail(error.BadDerivation, "impure derivations are not supported", .{});
    if (h.len == 0) {
        if (path.len != 0)
            return d.fail(error.BadDerivation, "content-addressing derivation output should not specify output path", .{});
        return .{ .ca_floating = .{ .method = method, .algo = algo } };
    }
    if (!std.mem.startsWith(u8, path, "/")) return d.fail(error.BadDerivation, "bad path '{s}' in derivation", .{path});
    return .{ .fixed = .{ .method = method, .hash = try Hash.parseNonSriUnprefixed(h, algo, d) } };
}

const Parser = struct {
    s: []const u8,
    pos: usize = 0,
    arena: Allocator,
    d: *Diag,

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.s.len) p.s[p.pos] else null;
    }

    fn expect(p: *Parser, comptime lit: []const u8) Error!void {
        if (!std.mem.startsWith(u8, p.s[p.pos..], lit))
            return p.d.fail(error.BadDerivation, "expected string '{s}' at offset {d}", .{ lit, p.pos });
        p.pos += lit.len;
    }

    /// Mirrors derivations.cc:endOfList.
    fn endOfList(p: *Parser) bool {
        const c = p.peek() orelse return false;
        if (c == ',' or c == ']') p.pos += 1;
        return c == ']';
    }

    fn string(p: *Parser) Error![]const u8 {
        const s = try p.bytes();
        if (!std.unicode.utf8ValidateSlice(s)) return p.d.fail(error.BadDerivation, "non-UTF-8 string in derivation", .{});
        return s;
    }

    /// Mirrors derivations.cc:parseString. A string with no escapes is a slice
    /// of the text.
    fn bytes(p: *Parser) Error![]const u8 {
        try p.expect("\"");
        const start = p.pos;
        const stop = std.mem.indexOfAnyPos(u8, p.s, start, "\"\\") orelse
            return p.d.fail(error.BadDerivation, "unterminated string in derivation", .{});
        if (p.s[stop] == '"') {
            p.pos = stop + 1;
            return p.s[start..stop];
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.arena, p.s[start..stop]);
        p.pos = stop;
        while (true) {
            const c = p.peek() orelse return p.d.fail(error.BadDerivation, "unterminated string in derivation", .{});
            p.pos += 1;
            switch (c) {
                '"' => return out.items,
                '\\' => {
                    const e = p.peek() orelse return p.d.fail(error.BadDerivation, "unterminated string in derivation", .{});
                    p.pos += 1;
                    try out.append(p.arena, switch (e) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => e,
                    });
                },
                else => try out.append(p.arena, c),
            }
        }
    }

    /// Mirrors derivations.cc:parsePath.
    fn path(p: *Parser) Error![]const u8 {
        const s = try p.string();
        if (!std.mem.startsWith(u8, s, "/")) return p.d.fail(error.BadDerivation, "bad path '{s}' in derivation", .{s});
        return s;
    }

    /// Mirrors derivations.cc:parseStrings, into a sorted set.
    fn stringList(p: *Parser) Error![]const []const u8 {
        var res: std.ArrayList([]const u8) = .empty;
        try p.expect("[");
        while (!p.endOfList()) try res.append(p.arena, try p.string());
        std.mem.sort([]const u8, res.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        var n: usize = 0;
        for (res.items) |s| {
            if (n > 0 and std.mem.eql(u8, res.items[n - 1], s)) continue;
            res.items[n] = s;
            n += 1;
        }
        return res.items[0..n];
    }

    /// Mirrors derivations.cc:parseDerivedPathMapNode. The leading comma is the
    /// one after the `.drv` path or the output name. An `xp-dyn-drv` derivation
    /// may still write the flat form for an input that has no dynamic output.
    fn inputNode(p: *Parser, dynamic: bool) Error!InputNode {
        try p.expect(",");
        if (!dynamic or p.peek() == '[') return .{ .outputs = try p.stringList() };
        if (p.peek() != '(') return p.d.fail(error.BadDerivation, "invalid inputDrvs entry in derivation", .{});
        try p.expect("(");
        const outputs = try p.stringList();
        try p.expect(",[");
        var children: std.ArrayList(InputNode.Child) = .empty;
        while (!p.endOfList()) {
            try p.expect("(");
            const name = try p.string();
            const child = try p.inputNode(dynamic);
            try p.expect(")");
            try children.append(p.arena, .{ .name = name, .node = child });
        }
        try p.expect(")");
        return .{ .outputs = outputs, .children = sortKeepLast(InputNode.Child, children.items, "name") };
    }
};

/// Mirrors derivations.hh:DrvHash.
pub const DrvHash = struct {
    /// By output name, sorted.
    hashes: []const OutputHash,
    kind: Kind,

    pub const Kind = enum { regular, deferred };
    pub const OutputHash = struct { name: []const u8, hash: Hash };

    pub fn get(h: DrvHash, output_name: []const u8) ?Hash {
        for (h.hashes) |o| if (std.mem.eql(u8, o.name, output_name)) return o.hash;
        return null;
    }
};

/// Memo of `hashDerivationModulo` per `.drv` path (derivations.cc:drvHashes).
/// Owns what it stores.
pub const DrvHashCache = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(DrvHash) = .empty,

    pub fn init(gpa: Allocator) DrvHashCache {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(c: *DrvHashCache) void {
        c.map.deinit(c.gpa);
        c.arena.deinit();
    }

    pub fn get(c: *const DrvHashCache, p: *const StorePath) ?DrvHash {
        return c.map.get(p.baseName());
    }

    pub fn contains(c: *const DrvHashCache, p: *const StorePath) bool {
        return c.map.contains(p.baseName());
    }

    /// Stores a copy of `h`, and returns it.
    pub fn put(c: *DrvHashCache, p: *const StorePath, h: DrvHash) Allocator.Error!DrvHash {
        const a = c.arena.allocator();
        const hashes = try a.alloc(DrvHash.OutputHash, h.hashes.len);
        for (h.hashes, hashes) |src, *dst| dst.* = .{ .name = try a.dupe(u8, src.name), .hash = src.hash };
        const stored: DrvHash = .{ .hashes = hashes, .kind = h.kind };
        try c.map.put(c.gpa, try a.dupe(u8, p.baseName()), stored);
        return stored;
    }
};

/// Reads a `.drv` that is not in the cache (Store::readInvalidDerivation).
/// The derivation goes into `arena`, which lives only while its hash is computed.
pub const Loader = struct {
    ctx: *anyopaque,
    loadFn: *const fn (ctx: *anyopaque, arena: Allocator, drv_path: StorePath, d: *Diag) Error!Derivation,

    pub fn load(l: Loader, arena: Allocator, drv_path: StorePath, d: *Diag) Error!Derivation {
        return l.loadFn(l.ctx, arena, drv_path, d);
    }
};

/// The default loader: reads `<store dir>/<hash>-<name>.drv` from the local store.
pub const StoreLoader = struct {
    io: Io,

    pub fn loader(s: *StoreLoader) Loader {
        return .{ .ctx = s, .loadFn = load };
    }

    fn load(ctx: *anyopaque, arena: Allocator, drv_path: StorePath, d: *Diag) Error!Derivation {
        const s: *StoreLoader = @ptrCast(@alignCast(ctx));
        return loadDerivationFromStore(s.io, arena, drv_path, d);
    }
};

/// Reads and parses `<store dir>/<hash>-<name>.drv`. Mirrors
/// Store::readInvalidDerivation for a local store.
pub fn loadDerivationFromStore(io: Io, arena: Allocator, drv_path: StorePath, d: *Diag) Error!Derivation {
    const name = try Derivation.nameFromPath(&drv_path, d);
    var buf: [4096]u8 = undefined;
    const full = drv_path.print(&buf);
    const text = Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return d.fail(error.BadDerivation, "cannot read derivation '{s}': {t}", .{ full, e }),
    };
    return Derivation.parse(arena, text, name, d);
}

/// Mirrors derivations.cc:hashDerivationModulo. The result is allocated in `arena`.
pub fn hashDerivationModulo(
    arena: Allocator,
    drv: *const Derivation,
    mask_outputs: bool,
    cache: *DrvHashCache,
    loader: Loader,
    d: *Diag,
) Error!DrvHash {
    if (drv.isFixed()) {
        const hashes = try arena.alloc(DrvHash.OutputHash, drv.outputs.len);
        for (drv.outputs, hashes) |o, *dst| {
            const f = o.output.fixed;
            const p = try drv.fixedOutputPath(o.name, d);
            var hasher: hash_mod.Hasher = .init(.sha256);
            var buf: [512]u8 = undefined;
            var hw = hasher.writer(&buf);
            hw.interface.print("fixed:out:{s}{s}:", .{ f.method.prefix(), f.hash.algo.name() }) catch unreachable;
            hash_mod.writeBase16(&hw.interface, f.hash.bytes()) catch unreachable;
            hw.interface.print(":{f}", .{&p}) catch unreachable;
            hw.interface.flush() catch unreachable;
            dst.* = .{ .name = o.name, .hash = hasher.finish() };
        }
        return .{ .hashes = hashes, .kind = .regular };
    }
    return hashModuloWith(arena, drv, mask_outputs, try moduloInputs(arena, drv, cache, loader, d), d);
}

/// `hashDerivationModulo` of a derivation that is not fixed-output, with the
/// inputs' part already computed (`moduloInputs`). Only that part needs the
/// cache, so a caller sharing the cache holds its lock for that alone and
/// hashes without it.
pub fn hashModuloWith(arena: Allocator, drv: *const Derivation, mask_outputs: bool, inputs: ModuloInputs, d: *Diag) Error!DrvHash {
    const h = try drv.hashAterm(.{ .mask_outputs = mask_outputs, .actual_inputs = inputs.inputs }, d);
    const hashes = try arena.alloc(DrvHash.OutputHash, drv.outputs.len);
    for (drv.outputs, hashes) |o, *dst| dst.* = .{ .name = o.name, .hash = h };
    return .{ .hashes = hashes, .kind = inputs.kind };
}

pub const ModuloInputs = struct { inputs: []const ModuloInput, kind: DrvHash.Kind };

/// The part of the hash modulo that depends on the inputs: each input
/// derivation replaced by its own hash modulo. Nix drops `children` here: only
/// the direct output names of each input go through the modulo hash.
pub fn moduloInputs(arena: Allocator, drv: *const Derivation, cache: *DrvHashCache, loader: Loader, d: *Diag) Error!ModuloInputs {
    var kind: DrvHash.Kind = .regular;
    for (drv.outputs) |o| if (o.output == .ca_floating) {
        kind = .deferred;
    };
    const Pair = struct { hex: [64]u8, output: []const u8 };
    var pairs: std.ArrayList(Pair) = .empty;
    for (drv.input_drvs) |in| {
        const res = try pathDerivationModulo(in.path, cache, loader, d);
        if (res.kind == .deferred) kind = .deferred;
        for (in.node.outputs) |out| {
            const h = res.get(out) orelse
                return d.fail(error.BadDerivation, "no hash for output '{s}' of derivation '{s}'", .{ out, drv.name });
            var pair: Pair = .{ .hex = undefined, .output = out };
            _ = h.print(&pair.hex, .base16, false);
            try pairs.append(arena, pair);
        }
    }
    // the same modulo hash covers every output of one input
    std.mem.sortUnstable(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return switch (std.mem.order(u8, &a.hex, &b.hex)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, a.output, b.output),
            };
        }
    }.lt);
    var inputs: std.ArrayList(ModuloInput) = .empty;
    var i: usize = 0;
    while (i < pairs.items.len) {
        const hex = pairs.items[i].hex;
        var outs: std.ArrayList([]const u8) = .empty;
        while (i < pairs.items.len and std.mem.eql(u8, &pairs.items[i].hex, &hex)) : (i += 1) {
            const o = pairs.items[i].output;
            if (outs.items.len == 0 or !std.mem.eql(u8, outs.items[outs.items.len - 1], o)) try outs.append(arena, o);
        }
        try inputs.append(arena, .{ .hex = hex, .outputs = outs.items });
    }
    return .{ .inputs = inputs.items, .kind = kind };
}

/// Mirrors derivations.cc:pathDerivationModulo, memoized by `.drv` path. The
/// result is owned by `cache`.
pub fn pathDerivationModulo(drv_path: StorePath, cache: *DrvHashCache, loader: Loader, d: *Diag) Error!DrvHash {
    if (cache.get(&drv_path)) |h| return h;
    var tmp: Scratch = .init(cache.gpa);
    defer tmp.deinit();
    const drv = try loader.load(tmp.allocator(), drv_path, d);
    const h = try hashDerivationModulo(tmp.allocator(), &drv, false, cache, loader, d);
    return cache.put(&drv_path, h);
}

/// Mirrors derivations.cc:Derivation::fillInOutputPaths as primops.cc:derivationStrict
/// uses it: deferred outputs become input-addressed paths from the masked hash
/// modulo, and the env entries named after the outputs are set to the paths
/// (fixed outputs included). Env strings are allocated in `arena`.
pub fn finalizeInputAddressedOutputs(
    arena: Allocator,
    drv: *Derivation,
    cache: *DrvHashCache,
    loader: Loader,
    d: *Diag,
) Error!void {
    return finalizeWithInputs(arena, drv, try moduloInputs(arena, drv, cache, loader, d), d);
}

/// `finalizeInputAddressedOutputs` with the inputs' part of the modulo hash
/// already computed, so it needs no cache.
pub fn finalizeWithInputs(arena: Allocator, drv: *Derivation, inputs: ModuloInputs, d: *Diag) Error!void {
    var masked: ?DrvHash = null;
    for (drv.outputs) |*o| {
        const actual: StorePath = switch (o.output) {
            .fixed => try drv.fixedOutputPath(o.name, d),
            .input_addressed, .deferred => blk: {
                const hm = masked orelse hm: {
                    masked = try hashModuloWith(arena, drv, true, inputs, d);
                    break :hm masked.?;
                };
                switch (hm.kind) {
                    .deferred => {
                        if (o.output == .input_addressed)
                            return d.fail(error.BadDerivation, "derivation has incorrect output '{f}', should be deferred", .{&o.output.input_addressed});
                        continue;
                    },
                    .regular => {
                        const h = hm.get(o.name) orelse
                            return d.fail(error.BadDerivation, "derivation produced no hash for output '{s}'", .{o.name});
                        const p = try path_mod.makeOutputPath(o.name, h, drv.name, d);
                        if (o.output == .input_addressed and !o.output.input_addressed.eql(&p))
                            return d.fail(error.BadDerivation, "derivation has incorrect output '{f}', should be '{f}'", .{ &o.output.input_addressed, &p });
                        o.output = .{ .input_addressed = p };
                        break :blk p;
                    },
                }
            },
            .ca_floating => continue,
        };
        var buf: [4096]u8 = undefined;
        const s = actual.print(&buf);
        const v = drv.envGet(o.name) orelse "";
        if (v.len == 0) {
            try drv.envSet(arena, o.name, try arena.dupe(u8, s));
        } else if (!std.mem.eql(u8, v, s)) {
            return d.fail(error.BadDerivation, "derivation has incorrect environment variable '{s}', should be '{s}' but is actually '{s}'", .{ o.name, s, v });
        }
    }
}

const testing = std.testing;

const fixture_names = [_][]const u8{
    "0fdrgjkjrlf9vi5xgyxfl6s8ihav2idi-dep2.drv",
    "1rpf3nddnjznxv3q2bf64vpn8zdz1ciw-nix-shell.drv",
    "3nc68wjzwn4x9lpanpz81c08wxxz1m32-serde_json-1.0.118.drv",
    "5ggyjv5q95wqz2bi551hv95h3bgcj7cv-cargo-src-toml-1.1.2+spec-1.1.0.drv",
    "68wl4z5l99r9hd5nrd8jp919spc1vh26-python3.14-syrupy-5.5.3.drv",
    "70xjjhahwa7h9899cldlc7qk964ry5qb-rayon-1.11.0.drv",
    "73as87hfqgllqymcyhn1bi8iman2wwqx-ia.drv",
    "7lzmd077k113qvkgmk0llcdgp6fqxzb4-ed-1.22.6.tar.lz.drv",
    "8hidygbx0p2fhcn2z8y7iw55z067jjrs-xz-5.8.3.drv",
    "al1hk8nxqjm207npmjm88xgpc6h681ps-brotli-1.2.0.drv",
    "d370b9hbls0nlbmrvryfvs5ssj6x3wg0-bzip2-1.0.8.drv",
    "dbxnagc7ynix4780dy81vzrjp6rz7pfj-crate-bitvec_helpers-3.1.5.tar.gz.drv",
    "fla55pimn35p45zf6q029ayc1zbp1cbv-source.drv",
    "i8hyq0lnz4p67cl1h5v0rjnlv6bv9kfa-isocline-1.0.9.drv",
    "jgmdq32140qyqq198i86i9763vxq4w3w-libpcap-1.10.6.tar.gz.drv",
    "jqqbqyr1fbcrsnllaimlajcv2wp2dqmc-source.drv",
    "l08mz21yd1f7f349bzn43nbd2pbg7gi0-source.drv",
    "la30iy3ccppzq4v15mdaq411ipc4lg55-faad2-2.11.2.drv",
    "pckkdf72dvcpi4l4cbg668xbfvyg4ps8-fx.drv",
    "qgks1zmli0kcdawfnj5zwg79zzzyjnir-unit-dbus-broker.service.drv",
    "r1rf2p01za5ckcbz87fjvdnz2mpvy3bz-gmp-6.2.1.tar.xz.drv",
    "shmhipwrx2gnpz7sv1kvgbi3hxc2qla9-db-4.8.30.drv",
    "sqjiq38d04j09g4dws6a9d644618zf21-fr.drv",
    "v63hgwqlrww835ah88kv81r3h1lx8ajz-gnumake-4.4.1.drv",
    "vlcxckkq3qad5dp748a5xypnkwq76azw-nix-shell-env.drv",
    "wgj4nv00ip0zkjhgs6bq3f6yrfikw0m5-dep.drv",
    "wy1n5hgf011nf49p5rfiqa5776jjn3iv-gnum4-1.4.20.drv",
    "y4yy79dipbn734xw9q4q134w5ch556zi-fs1.drv",
    "ym177pivxr4vhly63fpaclk3fpqm2f57-5883212311535a0046031d74d1568ae173c1e35b.patch.drv",
    "yny3hfw1scr09h57ilnyqxs0dksxw61y-gcc-4.6.4.drv",
    "yq58ig7m2spbxzwz79kand8590z333p9-lld-21.1.8.drv",
    "z4bz4ysldjwacldg0gahzg2hz6vza0ah-libxext-1.3.7.drv",
    "zg91q5d2vz5dx38r626idwvd89h6gna2-diffutils-3.12.tar.xz.drv",
};

/// Copies of /nix/store/*.drv produced by Nix 2.34.8, named by their store path.
const fixtures = blk: {
    var out: [fixture_names.len]struct { base: []const u8, text: []const u8 } = undefined;
    for (fixture_names, &out) |n, *f| f.* = .{ .base = n, .text = @embedFile("testdata/drv/" ++ n) };
    break :blk out;
};

fn fixtureText(base: []const u8) ?[]const u8 {
    for (fixtures) |f| if (std.mem.eql(u8, f.base, base)) return f.text;
    return null;
}

fn parseFixture(arena: Allocator, base: []const u8, d: *Diag) !Derivation {
    const p = try StorePath.fromBaseName(base, d);
    return Derivation.parse(arena, fixtureText(base).?, try Derivation.nameFromPath(&p, d), d);
}

/// The fixtures, then the local store.
const fixture_loader: Loader = .{ .ctx = undefined, .loadFn = struct {
    fn load(_: *anyopaque, arena: Allocator, drv_path: StorePath, d: *Diag) Error!Derivation {
        if (fixtureText(drv_path.baseName())) |text|
            return Derivation.parse(arena, text, try Derivation.nameFromPath(&drv_path, d), d);
        return loadDerivationFromStore(testing.io, arena, drv_path, d);
    }
}.load };

const no_loader: Loader = .{ .ctx = undefined, .loadFn = struct {
    fn load(_: *anyopaque, _: Allocator, drv_path: StorePath, d: *Diag) Error!Derivation {
        return d.fail(error.BadDerivation, "unexpected load of {f}", .{&drv_path});
    }
}.load };

fn expectPath(want: []const u8, p: StorePath) !void {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(want, p.print(&buf));
}

fn expectSameDrv(a: *const Derivation, b: *const Derivation, d: *Diag) !void {
    try testing.expectEqualStrings(a.name, b.name);
    const ta = try a.unparseAlloc(testing.allocator, .{}, d);
    defer testing.allocator.free(ta);
    const tb = try b.unparseAlloc(testing.allocator, .{}, d);
    defer testing.allocator.free(tb);
    try testing.expectEqualStrings(ta, tb);
}

test "fixtures round-trip byte-exact" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var fixed: usize = 0;
    var multi: usize = 0;
    var structured: usize = 0;
    for (fixtures) |f| {
        const drv = try parseFixture(arena.allocator(), f.base, &d);
        const text = try drv.unparseAlloc(testing.allocator, .{}, &d);
        defer testing.allocator.free(text);
        try testing.expectEqualStrings(f.text, text);
        fixed += @intFromBool(drv.isFixed());
        multi += @intFromBool(drv.outputs.len > 1);
        structured += @intFromBool(drv.structured_attrs != null);
    }
    try testing.expect(fixed >= 8);
    try testing.expect(multi >= 10);
    try testing.expect(structured >= 3);
}

test "fixtures drvPath matches the store path" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    for (fixtures) |f| {
        const drv = try parseFixture(arena.allocator(), f.base, &d);
        try testing.expectEqualStrings(f.base, (try drv.drvPath(testing.allocator, &d)).baseName());
        try testing.expectEqualStrings(f.base, (try drv.drvPathFor(testing.allocator, f.text, &d)).baseName());
    }
}

/// The whole input closure of `drv` is among the fixtures.
fn closureInFixtures(arena: Allocator, drv: *const Derivation, d: *Diag) bool {
    for (drv.input_drvs) |in| {
        if (fixtureText(in.path.baseName()) == null) return false;
        const sub = parseFixture(arena, in.path.baseName(), d) catch return false;
        if (!closureInFixtures(arena, &sub, d)) return false;
    }
    return true;
}

fn closureInStore(arena: Allocator, drv: *const Derivation, d: *Diag) bool {
    _ = arena;
    _ = d;
    for (drv.input_drvs) |in| {
        if (fixtureText(in.path.baseName()) != null) continue;
        var buf: [512]u8 = undefined;
        Io.Dir.cwd().access(testing.io, in.path.print(&buf), .{}) catch return false;
    }
    return true;
}

/// Resets every input-addressed output to deferred with an empty env value, as
/// primops.cc:derivationStrict does, then checks that finalizing reproduces the
/// original. Fixtures whose input closure `present` rejects are skipped.
fn recomputeFixtures(present: fn (Allocator, *const Derivation, *Diag) bool) !usize {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    var checked: usize = 0;
    for (fixtures) |f| {
        const original = try parseFixture(a, f.base, &d);
        if (!present(a, &original, &d)) continue;
        var drv = original;
        drv.outputs = try a.dupe(NamedOutput, original.outputs);
        drv.env = .empty;
        try drv.env.appendSlice(a, original.env.items);
        for (drv.outputs) |*o| if (o.output == .input_addressed) {
            o.output = .deferred;
            try drv.envSet(a, o.name, "");
        };
        try finalizeInputAddressedOutputs(a, &drv, &cache, fixture_loader, &d);
        try expectSameDrv(&original, &drv, &d);
        checked += 1;
    }
    return checked;
}

test "fixtures output paths recompute" {
    try testing.expect(try recomputeFixtures(closureInFixtures) >= 7);
}

// The nixpkgs fixtures have closures of hundreds of .drv files, too many to
// vendor; this checks those whose direct inputs are in /nix/store (and loads
// the rest of their closure from there).
test "fixtures output paths recompute from the store" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var present: usize = 0;
    for (fixtures) |f| {
        const drv = try parseFixture(arena.allocator(), f.base, &d);
        present += @intFromBool(closureInStore(arena.allocator(), &drv, &d));
    }
    if (present == 0) return error.SkipZigTest;
    try testing.expectEqual(present, try recomputeFixtures(closureInStore));
}

fn simple(a: Allocator, name: []const u8, outputs: []const []const u8) !Derivation {
    var drv: Derivation = .{ .name = name, .platform = "x86_64-linux", .builder = "/bin/sh" };
    const outs = try a.alloc(NamedOutput, outputs.len);
    for (outputs, outs) |o, *n| n.* = .{ .name = o, .output = .deferred };
    drv.outputs = sortKeepLast(NamedOutput, outs, "name");
    for (outputs) |o| try drv.envSet(a, o, "");
    try drv.envSet(a, "builder", "/bin/sh");
    try drv.envSet(a, "name", name);
    try drv.envSet(a, "system", "x86_64-linux");
    return drv;
}

// derivations.cc:unparseDerivedPathMapNode and parseDerivedPathMapNode. An
// input with children puts the whole derivation in the versioned form, and
// one without keeps the flat node even there.
test "a dynamic input writes the versioned ATerm and parses back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const dep = try StorePath.parse("/nix/store/00000000000000000000000000000000-dep.drv", &d);
    const plain = try StorePath.parse("/nix/store/11111111111111111111111111111111-plain.drv", &d);
    var drv = try simple(a, "dyn", &.{"out"});
    const out: []const []const u8 = &.{"out"};
    drv.input_drvs = &.{
        .{ .path = dep, .node = .{ .outputs = out, .children = &.{.{ .name = "out", .node = .{
            .outputs = out,
            .children = &.{.{ .name = "out", .node = .{ .outputs = out } }},
        } }} } },
        .{ .path = plain, .node = .{ .outputs = out } },
    };
    const aterm = try drv.unparseAlloc(a, .{}, &d);
    try testing.expect(std.mem.startsWith(u8, aterm, "DrvWithVersion(\"xp-dyn-drv\",["));
    try testing.expect(std.mem.indexOf(u8, aterm, "(\"/nix/store/00000000000000000000000000000000-dep.drv\"," ++
        "([\"out\"],[(\"out\",([\"out\"],[(\"out\",[\"out\"])]))]))") != null);
    try testing.expect(std.mem.indexOf(u8, aterm, "(\"/nix/store/11111111111111111111111111111111-plain.drv\",[\"out\"])") != null);
    const back = try Derivation.parse(a, aterm, "dyn", &d);
    try expectSameDrv(&drv, &back, &d);
    try testing.expectEqual(2, back.input_drvs[0].node.children[0].node.outputs.len + back.input_drvs[0].node.children[0].node.children.len);

    // without children the traditional form comes back
    drv.input_drvs = drv.input_drvs[1..];
    const flat = try drv.unparseAlloc(a, .{}, &d);
    try testing.expect(std.mem.startsWith(u8, flat, "Derive(["));
    const back2 = try Derivation.parse(a, flat, "dyn", &d);
    try expectSameDrv(&drv, &back2, &d);
}

// nix-instantiate drvs.nix -A ia, with
//   ia = builtins.derivation { name = "ia"; system = "x86_64-linux"; builder = "/bin/sh";
//     args = ["-c" "x\"y\\z\n"]; outputs = ["out" "dev"]; FOO = "b\tar"; };
test "input-addressed multi-output from scratch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var drv = try simple(a, "ia", &.{ "out", "dev" });
    drv.args = &.{ "-c", "x\"y\\z\n" };
    try drv.envSet(a, "FOO", "b\tar");
    try drv.envSet(a, "outputs", "out dev");
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    try finalizeInputAddressedOutputs(a, &drv, &cache, no_loader, &d);
    try expectPath("/nix/store/73as87hfqgllqymcyhn1bi8iman2wwqx-ia.drv", try drv.drvPath(a, &d));
    try expectPath("/nix/store/0rzxv3xkkgply9jd76fdiwfm6k1gyj6p-ia", drv.output("out").?.output.input_addressed);
    try expectPath("/nix/store/nx6zsacidiymqhs3yji2j0i0srcnnvkc-ia-dev", drv.output("dev").?.output.input_addressed);
    try testing.expectEqualStrings("/nix/store/nx6zsacidiymqhs3yji2j0i0srcnnvkc-ia-dev", drv.envGet("dev").?);
    try testing.expectEqualStrings(fixtureText("73as87hfqgllqymcyhn1bi8iman2wwqx-ia.drv").?, try drv.unparseAlloc(a, .{}, &d));
}

// nix-instantiate drvs.nix -A fr, with
//   fr = builtins.derivation { name = "fr"; system = "x86_64-linux"; builder = "/bin/sh";
//     outputHash = "ba78...15ad"; outputHashAlgo = "sha256"; outputHashMode = "recursive"; };
test "fixed output from scratch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    var drv = try simple(a, "fr", &.{});
    const outs = try a.alloc(NamedOutput, 1);
    outs[0] = .{ .name = "out", .output = .{ .fixed = .{ .method = .recursive, .hash = try Hash.parseAny(hex, .sha256, &d) } } };
    drv.outputs = outs;
    try drv.envSet(a, "outputHash", hex);
    try drv.envSet(a, "outputHashAlgo", "sha256");
    try drv.envSet(a, "outputHashMode", "recursive");
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    try finalizeInputAddressedOutputs(a, &drv, &cache, no_loader, &d);
    try testing.expectEqualStrings("/nix/store/s05rl80bpix1186wb5f471k7fxwwp7lf-fr", drv.envGet("out").?);
    try expectPath("/nix/store/sqjiq38d04j09g4dws6a9d644618zf21-fr.drv", try drv.drvPath(a, &d));
    try testing.expectEqualStrings(fixtureText("sqjiq38d04j09g4dws6a9d644618zf21-fr.drv").?, try drv.unparseAlloc(a, .{}, &d));
}

// nix-instantiate drvs.nix -A dep2, with
//   dep = builtins.derivation { name = "dep"; system = "x86_64-linux"; builder = "/bin/sh";
//     f = fx; src = builtins.toFile "a" "x"; };
//   dep2 = builtins.derivation { name = "dep2"; system = "x86_64-linux"; builder = "/bin/sh";
//     d = ia.dev; e = "${dep}"; };
// This exercises the fixed-output special case (fx) and the recursion through the cache.
test "input drvs hash modulo from scratch" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const ia = try StorePath.parse("/nix/store/73as87hfqgllqymcyhn1bi8iman2wwqx-ia.drv", &d);
    const dep = try StorePath.parse("/nix/store/wgj4nv00ip0zkjhgs6bq3f6yrfikw0m5-dep.drv", &d);
    var drv = try simple(a, "dep2", &.{"out"});
    try drv.envSet(a, "d", "/nix/store/nx6zsacidiymqhs3yji2j0i0srcnnvkc-ia-dev");
    try drv.envSet(a, "e", "/nix/store/pzjq1hdf1x9qs1dxcqiba82dyl1274aa-dep");
    drv.input_drvs = &.{
        .{ .path = ia, .node = .{ .outputs = &.{"dev"} } },
        .{ .path = dep, .node = .{ .outputs = &.{"out"} } },
    };
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    try finalizeInputAddressedOutputs(a, &drv, &cache, fixture_loader, &d);
    try expectPath("/nix/store/0fdrgjkjrlf9vi5xgyxfl6s8ihav2idi-dep2.drv", try drv.drvPath(a, &d));
    try testing.expectEqualStrings("/nix/store/f1lfacbx1gq8g6pw0290cijhli2n3nls-dep2", drv.envGet("out").?);
    try testing.expect(cache.contains(&dep));
    try testing.expect(cache.contains(&try StorePath.parse("/nix/store/pckkdf72dvcpi4l4cbg668xbfvyg4ps8-fx.drv", &d)));
}

test "string escapes round-trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeString(&w, "a\"b\\c\nd\re\tf$g");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf$g\"", w.buffered());
    var p: Parser = .{ .s = w.buffered(), .arena = a, .d = &d };
    try testing.expectEqualStrings("a\"b\\c\nd\re\tf$g", try p.string());
    var p2: Parser = .{ .s = "\"abc", .arena = a, .d = &d };
    try testing.expectError(error.BadDerivation, p2.string());
    var p3: Parser = .{ .s = "\"abc\\", .arena = a, .d = &d };
    try testing.expectError(error.BadDerivation, p3.string());
    try testing.expectEqualStrings("unterminated string in derivation", d.message());
    const plain = "\"plain\"";
    var p4: Parser = .{ .s = plain, .arena = a, .d = &d };
    // no escapes: a slice of the text
    try testing.expectEqual(plain[1..].ptr, (try p4.string()).ptr);
}

// The ATerm is streamed into the hasher rather than unparsed whole, so it
// must hash what a full unparse holds.
test "a streamed unparse hashes as the full unparse" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    for (fixtures) |f| {
        const drv = try parseFixture(a, f.base, &d);
        for ([_]bool{ false, true }) |mask| {
            const text = try drv.unparseAlloc(a, .{ .mask_outputs = mask }, &d);
            try testing.expect(hash_mod.hashBytes(.sha256, text).eql(try drv.hashAterm(.{ .mask_outputs = mask }, &d)));
        }
    }
    var drv = try simple(a, "tail", &.{ "dev", "out" });
    drv.args = &.{ "-c", "echo \"$out\"\n\t\\\r\xff" };
    try drv.envSet(a, "script", "a\"b\\c\nd\re\tf\xfe$");
    try finalizeInputAddressedOutputs(a, &drv, &cache, fixture_loader, &d);
    const text = try drv.unparseAlloc(a, .{}, &d);
    const back = try Derivation.parse(a, text, "tail", &d);
    try expectSameDrv(&drv, &back, &d);
    try testing.expectEqualStrings("echo \"$out\"\n\t\\\r\xff", back.args[1]);

    var drv2 = try simple(a, "tail", &.{ "dev", "out" });
    drv2.structured_attrs = "{\"out\":\"\\\"\\n\"}";
    drv2.envRemove("dev");
    try finalizeInputAddressedOutputs(a, &drv2, &cache, fixture_loader, &d);
    try testing.expect(drv2.envGet("dev") != null);
    const text2 = try drv2.unparseAlloc(a, .{}, &d);
    try testing.expect(std.mem.indexOf(u8, text2, "(\"__json\",\"{\\\"out\\\":\\\"\\\\\\\"\\\\n\\\"}\"),(\"builder\"") != null);
    const back2 = try Derivation.parse(a, text2, "tail", &d);
    try expectSameDrv(&drv2, &back2, &d);
}

test "masked unparse blanks output paths and env" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const drv = try parseFixture(arena.allocator(), "73as87hfqgllqymcyhn1bi8iman2wwqx-ia.drv", &d);
    const masked = try drv.unparseAlloc(arena.allocator(), .{ .mask_outputs = true }, &d);
    try testing.expect(std.mem.startsWith(u8, masked, "Derive([(\"dev\",\"\",\"\",\"\"),(\"out\",\"\",\"\",\"\")],"));
    try testing.expect(std.mem.indexOf(u8, masked, "(\"dev\",\"\")") != null);
    try testing.expect(std.mem.indexOf(u8, masked, "(\"out\",\"\")") != null);
    try testing.expect(std.mem.indexOf(u8, masked, "/nix/store/0rzxv3xkkgply9jd76fdiwfm6k1gyj6p-ia") == null);
}

test "an env key named __json is refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var drv: Derivation = .{ .name = "o1", .platform = "x", .builder = "/bin/sh" };
    try drv.envSet(arena.allocator(), "__json", "/nix/store/x");
    try testing.expectError(error.BadDerivation, drv.hashAterm(.{}, &d));
    try testing.expectEqualStrings("Cannot have an environment variable named '__json'. This key is reserved for encoding structured attrs", d.message());
}

test "parse errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.BadDerivation, Derivation.parse(a, "Derive([(", "x", &d));
    try testing.expectEqualStrings("expected string '\"' at offset 9", d.message());
    try testing.expectError(error.BadDerivation, Derivation.parse(a, "DrvWithVersion(\"v2\",[", "x", &d));
    try testing.expectEqualStrings("derivation 'x', ATerm format version 'v2' is not supported", d.message());
    try testing.expectError(error.BadDerivation, Derivation.parse(a, "Derive([(\"out\",\"\",\"git:sha1\",\"\")", "x", &d));
    try testing.expectEqualStrings("unsupported output hash method 'git:sha1'", d.message());
    try testing.expectError(error.BadDerivation, Derivation.parse(a, "Derive([(\"out\",\"\",\"sha256\",\"impure\")", "x", &d));
    try testing.expectEqualStrings("impure derivations are not supported", d.message());
    try testing.expectError(error.BadDerivation, Derivation.parse(a, "Derive([(\"out\",\"/x\",\"r:sha256\",\"\")", "x", &d));
    try testing.expectEqualStrings("content-addressing derivation output should not specify output path", d.message());
    try testing.expectError(error.BadDerivation, Derivation.parse(a, "Derive([(\"out\",\"\",\"\xff\",\"\")", "x", &d));
    try testing.expectEqualStrings("non-UTF-8 string in derivation", d.message());
    const p = try StorePath.parse("/nix/store/00000000000000000000000000000000-x", &d);
    try testing.expectError(error.BadDerivation, Derivation.nameFromPath(&p, &d));
    try testing.expectEqualStrings("'/nix/store/00000000000000000000000000000000-x' is not a derivation path", d.message());
}

test "a floating CA output defers its dependents" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var drv = try simple(a, "ca", &.{"out"});
    drv.outputs[0].output = .{ .ca_floating = .{ .method = .recursive, .algo = .sha256 } };
    try drv.envSet(a, "out", &path_mod.hashPlaceholder("out"));
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    try finalizeInputAddressedOutputs(a, &drv, &cache, no_loader, &d);
    try testing.expect(drv.outputs[0].output == .ca_floating);
    const h = try hashDerivationModulo(a, &drv, false, &cache, no_loader, &d);
    try testing.expectEqual(.deferred, h.kind);
}
