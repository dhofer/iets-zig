//! `nix derivation show`'s JSON: the derivations a set of roots names, and
//! with `recursive` their whole input-derivation closure. Each ATerm comes
//! from the evaluation's derivation table (`plan.Inputs`), so the answer
//! needs nothing in `/nix/store`; a drv the evaluation did not make is read
//! from there (docs/reference/classic.md, docs/reference/divergences.md).

const std = @import("std");
const text_ = @import("../syntax/text.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const Diag = @import("../diag.zig").Diag;
const log = @import("../log.zig");
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const IngestionMethod = path_mod.IngestionMethod;
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const plan = @import("../remote/plan.zig");

/// derivations.hh:expectedJsonVersionDerivation.
pub const version = 4;

/// Writes the whole `nix derivation show` document, `{"derivations": {…},
/// "version": 4}` keyed by base name, and a newline: nlohmann's `dump()`,
/// indented by two spaces when `pretty`. A root that is not a `.drv` is
/// dropped, as derivation-show.cc drops it. Errors are remote.zig's kinds
/// (`Io`, `Store`), the message in `d`.
pub fn show(gpa: Allocator, io: Io, w: *Writer, roots: []const StorePath, recursive: bool, pretty: bool, inputs: plan.Inputs, d: *Diag) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var drvs: std.ArrayList(StorePath) = .empty;
    for (roots) |p| if (p.isDerivation()) try drvs.append(arena, p);
    const nodes = if (recursive) try closure(gpa, arena, io, drvs.items, inputs, d) else try tops(arena, io, drvs.items, inputs, d);
    // nlohmann's object is a sorted map
    std.mem.sortUnstable(Node, nodes, {}, struct {
        fn lt(_: void, x: Node, y: Node) bool {
            return x.path.order(&y.path) == .lt;
        }
    }.lt);

    var j: Json = .{ .w = w, .pretty = pretty };
    try j.open('{');
    try j.key("derivations");
    try j.open('{');
    for (nodes) |n| {
        const name = Derivation.nameFromPath(&n.path, d) catch return error.Store;
        const drv = Derivation.parse(arena, n.aterm, name, d) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Store,
        };
        try j.key(n.path.baseName());
        try derivation(&j, &drv);
    }
    try j.close('}');
    try j.key("version");
    try j.number(version);
    try j.close('}');
    try w.writeByte('\n');
}

const Node = struct { path: StorePath, aterm: []const u8 };

/// The roots themselves, deduplicated.
fn tops(arena: Allocator, io: Io, roots: []const StorePath, inputs: plan.Inputs, d: *Diag) ![]Node {
    var out: std.ArrayList(Node) = .empty;
    outer: for (roots, 0..) |p, i| {
        for (roots[0..i]) |q| if (q.eql(&p)) continue :outer;
        const l = try plan.loadDrv(arena, io, &p, inputs, d);
        try out.append(arena, .{ .path = p, .aterm = l.aterm });
    }
    return out.items;
}

/// `-r`: every derivation the roots reach through `inputDrvs`. This is
/// `computeFSClosure` over the roots with the sources dropped, except that
/// the closure is read from the derivation table first and `/nix/store`
/// only for what the table lacks.
fn closure(gpa: Allocator, arena: Allocator, io: Io, roots: []const StorePath, inputs: plan.Inputs, d: *Diag) ![]Node {
    const none: plan.PathSet = .empty;
    const walk = try plan.walk(gpa, arena, io, roots, &none, inputs, d);
    const out = try arena.alloc(Node, walk.drvs.len);
    for (walk.drvs, out) |n, *o| o.* = .{ .path = n.path, .aterm = n.aterm };
    return out;
}

/// derivations.cc:adl_serializer<Derivation>::to_json, keys sorted.
fn derivation(j: *Json, drv: *const Derivation) Writer.Error!void {
    try j.open('{');
    try j.key("args");
    try j.open('[');
    for (drv.args) |a| try j.string(a);
    try j.close(']');
    try j.key("builder");
    try j.string(drv.builder);
    try j.key("env");
    try j.open('{');
    for (drv.env.items) |e| {
        try j.key(e.key);
        try j.string(e.value);
    }
    try j.close('}');
    try j.key("inputs");
    try j.open('{');
    try j.key("drvs");
    try j.open('{');
    for (drv.input_drvs) |in| {
        try j.key(in.path.baseName());
        try inputNode(j, in.node);
    }
    try j.close('}');
    try j.key("srcs");
    try j.open('[');
    for (drv.input_srcs) |p| try j.string(p.baseName());
    try j.close(']');
    try j.close('}');
    try j.key("name");
    try j.string(drv.name);
    try j.key("outputs");
    try j.open('{');
    for (drv.outputs) |o| {
        try j.key(o.name);
        try output(j, o.output);
    }
    try j.close('}');
    // nix parses `__json` out of the env and dumps the parsed value; the
    // parse already normalised it to that text
    if (drv.structured_attrs) |sa| {
        try j.key("structuredAttrs");
        try j.raw(sa);
    }
    try j.key("system");
    try j.string(drv.platform);
    try j.key("version");
    try j.number(version);
    try j.close('}');
}

/// One `inputDrvs` entry (derived-path-map.cc:to_json of a ChildNode): the
/// outputs used, and those of the outputs that are themselves derivations.
fn inputNode(j: *Json, n: drv_mod.InputNode) Writer.Error!void {
    try j.open('{');
    try j.key("dynamicOutputs");
    try j.open('{');
    for (n.children) |c| {
        try j.key(c.name);
        try inputNode(j, c.node);
    }
    try j.close('}');
    try j.key("outputs");
    try j.open('[');
    for (n.outputs) |o| try j.string(o);
    try j.close(']');
    try j.close('}');
}

/// derivations.cc:adl_serializer<DerivationOutput>::to_json. A fixed output
/// carries its content address, not its path, which nix leaves out because
/// the serializer does not know the store directory.
fn output(j: *Json, o: drv_mod.Output) Writer.Error!void {
    try j.open('{');
    switch (o) {
        .input_addressed => |p| {
            try j.key("path");
            try j.string(p.baseName());
        },
        .fixed => |f| {
            try j.key("hash");
            var buf: [128]u8 = undefined;
            try j.string(f.hash.print(&buf, .sri, true));
            try j.key("method");
            try j.string(render(f.method));
        },
        .ca_floating => |f| {
            try j.key("hashAlgo");
            try j.string(f.algo.name());
            try j.key("method");
            try j.string(render(f.method));
        },
        .deferred => {},
    }
    try j.close('}');
}

/// content-address.cc:ContentAddressMethod::render.
fn render(m: IngestionMethod) []const u8 {
    return switch (m) {
        .flat => "flat",
        .recursive => "nar",
        .text => "text",
    };
}

/// A JSON writer in nlohmann's `dump()` form, which Rust iets's matches:
/// compact, or indented by two spaces with `": "` after a key; an empty
/// object or array is `{}` or `[]` either way.
const Json = struct {
    w: *Writer,
    pretty: bool,
    depth: usize = 0,
    /// Nothing written yet in the innermost open object or array.
    first: bool = true,
    /// A key was written: its value comes without a separator.
    after_key: bool = false,
    /// A key was written: its value comes without a separator.
    fn newline(j: *Json) Writer.Error!void {
        try j.w.writeByte('\n');
        try j.w.splatByteAll(' ', 2 * j.depth);
    }

    /// Before an element of an array, or a key.
    fn elem(j: *Json) Writer.Error!void {
        if (j.depth == 0) return;
        if (!j.first) try j.w.writeByte(',');
        j.first = false;
        if (j.pretty) try j.newline();
    }

    fn open(j: *Json, c: u8) Writer.Error!void {
        try j.value();
        try j.w.writeByte(c);
        j.depth += 1;
        j.first = true;
    }

    fn close(j: *Json, c: u8) Writer.Error!void {
        j.depth -= 1;
        if (!j.first and j.pretty) try j.newline();
        try j.w.writeByte(c);
        j.first = false;
    }

    fn key(j: *Json, k: []const u8) Writer.Error!void {
        try j.elem();
        try text_.writeJsonString(j.w, k);
        try j.w.writeAll(if (j.pretty) ": " else ":");
        j.after_key = true;
    }

    fn number(j: *Json, n: u64) Writer.Error!void {
        try j.value();
        try j.w.print("{d}", .{n});
    }

    /// An array element, or the value after a key.
    fn string(j: *Json, s: []const u8) Writer.Error!void {
        try j.value();
        try text_.writeJsonString(j.w, s);
    }

    /// The value after a key needs no separator; an array element does.
    fn value(j: *Json) Writer.Error!void {
        if (j.after_key) {
            j.after_key = false;
            return;
        }
        try j.elem();
    }

    /// `text`, compact JSON, re-indented at this depth when pretty.
    fn raw(j: *Json, text: []const u8) Writer.Error!void {
        try j.value();
        if (!j.pretty) return j.w.writeAll(text);
        var depth = j.depth;
        var i: usize = 0;
        var in_string = false;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (in_string) {
                try j.w.writeByte(c);
                if (c == '\\') {
                    i += 1;
                    try j.w.writeByte(text[i]);
                } else if (c == '"') in_string = false;
                continue;
            }
            switch (c) {
                '"' => {
                    in_string = true;
                    try j.w.writeByte(c);
                },
                '{', '[' => {
                    if (i + 1 < text.len and text[i + 1] == c + 2) {
                        try j.w.writeAll(&.{ c, c + 2 });
                        i += 1;
                        continue;
                    }
                    try j.w.writeByte(c);
                    depth += 1;
                    try j.w.writeByte('\n');
                    try j.w.splatByteAll(' ', 2 * depth);
                },
                '}', ']' => {
                    depth -= 1;
                    try j.w.writeByte('\n');
                    try j.w.splatByteAll(' ', 2 * depth);
                    try j.w.writeByte(c);
                },
                ',' => {
                    try j.w.writeByte(',');
                    try j.w.writeByte('\n');
                    try j.w.splatByteAll(' ', 2 * depth);
                },
                ':' => try j.w.writeAll(": "),
                else => try j.w.writeByte(c),
            }
        }
    }
};

// Tests

const testing = std.testing;

fn jsonOf(aterm: []const u8, name: []const u8, pretty: bool) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const drv = try Derivation.parse(arena.allocator(), aterm, name, &d);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var j: Json = .{ .w = &out.writer, .pretty = pretty };
    try derivation(&j, &drv);
    return out.toOwnedSlice();
}

// Each pair is one `.drv` and what `nix derivation show` printed for it,
// captured from `nix (Nix) 2.34.8` on a case built for it.
const cases = [_]struct { name: []const u8, aterm: []const u8, want: []const u8 }{
    .{
        // a multi-output derivation
        .name = "drvshow-multi",
        .aterm =
        \\Derive([("dev","/nix/store/y7a2ldlsm4a9b89dy8gjq9w2jxrg9ni7-drvshow-multi-dev","",""),("out","/nix/store/glmm5g4k4ni9sqr84qzq47c7z839qy2v-drvshow-multi","","")],[],[],"x86_64-linux","/bin/sh",["-c","echo a > $out; echo b > $dev"],[("builder","/bin/sh"),("dev","/nix/store/y7a2ldlsm4a9b89dy8gjq9w2jxrg9ni7-drvshow-multi-dev"),("name","drvshow-multi"),("out","/nix/store/glmm5g4k4ni9sqr84qzq47c7z839qy2v-drvshow-multi"),("outputs","out dev"),("system","x86_64-linux")])
        ,
        .want =
        \\{"args":["-c","echo a > $out; echo b > $dev"],"builder":"/bin/sh","env":{"builder":"/bin/sh","dev":"/nix/store/y7a2ldlsm4a9b89dy8gjq9w2jxrg9ni7-drvshow-multi-dev","name":"drvshow-multi","out":"/nix/store/glmm5g4k4ni9sqr84qzq47c7z839qy2v-drvshow-multi","outputs":"out dev","system":"x86_64-linux"},"inputs":{"drvs":{},"srcs":[]},"name":"drvshow-multi","outputs":{"dev":{"path":"y7a2ldlsm4a9b89dy8gjq9w2jxrg9ni7-drvshow-multi-dev"},"out":{"path":"glmm5g4k4ni9sqr84qzq47c7z839qy2v-drvshow-multi"}},"system":"x86_64-linux","version":4}
        ,
    },
    .{
        // a fixed output shows its content address and no path
        .name = "drvshow-fod",
        .aterm =
        \\Derive([("out","/nix/store/fzwqzgk7sxbw469w1hhbp686hlxgwpkx-drvshow-fod","r:sha1","0000000000000000000000000000000000000000")],[],[],"x86_64-linux","/bin/sh",["-c","echo x > $out"],[("builder","/bin/sh"),("name","drvshow-fod"),("out","/nix/store/fzwqzgk7sxbw469w1hhbp686hlxgwpkx-drvshow-fod"),("outputHash","0000000000000000000000000000000000000000"),("outputHashAlgo","sha1"),("outputHashMode","recursive"),("system","x86_64-linux")])
        ,
        .want =
        \\{"args":["-c","echo x > $out"],"builder":"/bin/sh","env":{"builder":"/bin/sh","name":"drvshow-fod","out":"/nix/store/fzwqzgk7sxbw469w1hhbp686hlxgwpkx-drvshow-fod","outputHash":"0000000000000000000000000000000000000000","outputHashAlgo":"sha1","outputHashMode":"recursive","system":"x86_64-linux"},"inputs":{"drvs":{},"srcs":[]},"name":"drvshow-fod","outputs":{"out":{"hash":"sha1-AAAAAAAAAAAAAAAAAAAAAAAAAAA=","method":"nar"}},"system":"x86_64-linux","version":4}
        ,
    },
    .{
        // inputs and structured attrs
        .name = "drvshow-top",
        .aterm =
        \\Derive([("out","/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top","","")],[("/nix/store/swp3gmqyvz1k2yjkmncfb29zhdhqfjmn-drvshow-dep.drv",["dev"])],["/nix/store/yb554rm2xvp2vbjgyc3zanbxmdaqnnqh-note"],"x86_64-linux","/bin/sh",["-c","true"],[("__json","{\"builder\":\"/bin/sh\",\"d\":\"/nix/store/p4pq1jgwyjlyc13nk7vv65a99jzw1843-drvshow-dep-dev\",\"n\":2,\"name\":\"drvshow-top\",\"system\":\"x86_64-linux\",\"t\":\"/nix/store/yb554rm2xvp2vbjgyc3zanbxmdaqnnqh-note\"}"),("out","/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top")])
        ,
        .want =
        \\{"args":["-c","true"],"builder":"/bin/sh","env":{"out":"/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top"},"inputs":{"drvs":{"swp3gmqyvz1k2yjkmncfb29zhdhqfjmn-drvshow-dep.drv":{"dynamicOutputs":{},"outputs":["dev"]}},"srcs":["yb554rm2xvp2vbjgyc3zanbxmdaqnnqh-note"]},"name":"drvshow-top","outputs":{"out":{"path":"5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top"}},"structuredAttrs":{"builder":"/bin/sh","d":"/nix/store/p4pq1jgwyjlyc13nk7vv65a99jzw1843-drvshow-dep-dev","n":2,"name":"drvshow-top","system":"x86_64-linux","t":"/nix/store/yb554rm2xvp2vbjgyc3zanbxmdaqnnqh-note"},"system":"x86_64-linux","version":4}
        ,
    },
};

test "the JSON of a derivation" {
    for (cases) |c| {
        const got = try jsonOf(c.aterm, c.name, false);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "a non-canonical structured attrs text is renormalised" {
    const aterm =
        \\Derive([("out","/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top","","")],[],[],"x86_64-linux","/bin/sh",[],[("__json","{ \"b\" : 2, \"a\": [1, 1e-5, {}] }"),("out","/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top")])
    ;
    const got = try jsonOf(aterm, "drvshow-top", false);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "\"structuredAttrs\":{\"a\":[1,1e-05,{}],\"b\":2}") != null);
}

// `--pretty` is the indented form Rust iets writes, structured attrs included.
test "pretty indents by two spaces" {
    const aterm =
        \\Derive([("out","/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top","","")],[],[],"x86_64-linux","/bin/sh",[],[("__json","{\"a\":{\"b\":[1,\"t,:{\",{},[],null,true]},\"c\":\"x\\\"]\",\"d\":{},\"e\":[]}"),("out","/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top")])
    ;
    const got = try jsonOf(aterm, "drvshow-top", true);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\{
        \\  "args": [],
        \\  "builder": "/bin/sh",
        \\  "env": {
        \\    "out": "/nix/store/5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top"
        \\  },
        \\  "inputs": {
        \\    "drvs": {},
        \\    "srcs": []
        \\  },
        \\  "name": "drvshow-top",
        \\  "outputs": {
        \\    "out": {
        \\      "path": "5railz2b3ssvqdssggdsnga8dyahvbaj-drvshow-top"
        \\    }
        \\  },
        \\  "structuredAttrs": {
        \\    "a": {
        \\      "b": [
        \\        1,
        \\        "t,:{",
        \\        {},
        \\        [],
        \\        null,
        \\        true
        \\      ]
        \\    },
        \\    "c": "x\"]",
        \\    "d": {},
        \\    "e": []
        \\  },
        \\  "system": "x86_64-linux",
        \\  "version": 4
        \\}
    , got);
}

const DrvTable = struct {
    entries: []const struct { path: StorePath, aterm: []const u8 },

    fn get(ctx: ?*anyopaque, p: *const StorePath) ?plan.DrvInfo {
        const t: *const DrvTable = @ptrCast(@alignCast(ctx.?));
        for (t.entries) |e| if (e.path.eql(p)) return .{ .aterm = e.aterm, .references = &.{} };
        return null;
    }
};

test "the document comes from the evaluation's table, sorted and deduplicated" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const fod = try StorePath.fromBaseName("fzwqzgk7sxbw469w1hhbp686hlxgwpkx-drvshow-fod.drv", &d);
    const multi = try StorePath.fromBaseName("aaaazgk7sxbw469w1hhbp686hlxgwpkx-drvshow-multi.drv", &d);
    const src = try StorePath.fromBaseName("yb554rm2xvp2vbjgyc3zanbxmdaqnnqh-note", &d);
    var table: DrvTable = .{ .entries = &.{ .{ .path = fod, .aterm = cases[1].aterm }, .{ .path = multi, .aterm = cases[0].aterm } } };
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try show(testing.allocator, testing.io, &out.writer, &.{ fod, multi, src, fod }, false, false, .{ .ctx = &table, .drv = DrvTable.get }, &d);
    const want = "{\"derivations\":{\"aaaazgk7sxbw469w1hhbp686hlxgwpkx-drvshow-multi.drv\":" ++ cases[0].want ++
        ",\"fzwqzgk7sxbw469w1hhbp686hlxgwpkx-drvshow-fod.drv\":" ++ cases[1].want ++ "},\"version\":4}\n";
    try testing.expectEqualStrings(want, out.written());

    out.clearRetainingCapacity();
    try show(testing.allocator, testing.io, &out.writer, &.{}, true, true, .{}, &d);
    try testing.expectEqualStrings("{\n  \"derivations\": {},\n  \"version\": 4\n}\n", out.written());
}

// `IETS_TEST_DRVSHOW` names `.drv` paths in the local store; each is shown,
// plain, recursive and pretty, and compared with what the machine's
// `nix derivation show` prints for it.
test "the same document as nix derivation show" {
    const list = testing.environ.getPosix("IETS_TEST_DRVSHOW") orelse return error.SkipZigTest;
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    var it = std.mem.tokenizeAny(u8, list, " \n");
    while (it.next()) |full| {
        const p = try StorePath.parse(full, &d);
        for ([_]bool{ false, true }) |recursive| for ([_]bool{ false, true }) |pretty| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(testing.allocator);
            try argv.appendSlice(testing.allocator, &.{ "nix", "--extra-experimental-features", "nix-command", "derivation", "show" });
            if (recursive) try argv.append(testing.allocator, "-r");
            try argv.append(testing.allocator, if (pretty) "--pretty" else "--no-pretty");
            try argv.append(testing.allocator, full);
            const res = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items, .stdout_limit = .unlimited });
            defer testing.allocator.free(res.stdout);
            defer testing.allocator.free(res.stderr);
            var out: Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            try show(testing.allocator, testing.io, &out.writer, &.{p}, recursive, pretty, .{}, &d);
            testing.expectEqualStrings(res.stdout, out.written()) catch |e| {
                std.debug.print("{s} recursive={} pretty={}\n", .{ full, recursive, pretty });
                return e;
            };
        };
    }
}
