//! The ATerm code against data it was not written from: Nix 2.34.8's own
//! libstore unit-test data (`src/libstore-tests/data/derivation`, copied to
//! `src/testdata/aterm` and the invariants cases below), and the hand-written
//! cases harmonia (github.com/nix-community/harmonia, MIT) checks its ATerm
//! code with.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const drv_mod = @import("drv.zig");
const Derivation = drv_mod.Derivation;
const Output = drv_mod.Output;
const NamedOutput = drv_mod.NamedOutput;
const InputDrv = drv_mod.InputDrv;
const EnvVar = drv_mod.EnvVar;
const DrvHashCache = drv_mod.DrvHashCache;
const Loader = drv_mod.Loader;
const Hash = @import("hash.zig").Hash;
const path_mod = @import("path.zig");
const StorePath = path_mod.StorePath;

fn fixture(comptime file: []const u8) []const u8 {
    return @embedFile("../testdata/aterm/" ++ file);
}

/// Every test gets an arena for derivations and a `Diag` whose message is
/// printed when a step fails unexpectedly.
const Env = struct {
    arena: std.heap.ArenaAllocator,
    d: Diag,

    fn init() Env {
        return .{ .arena = .init(testing.allocator), .d = .init(testing.allocator) };
    }

    fn deinit(e: *Env) void {
        e.d.deinit();
        e.arena.deinit();
    }

    fn a(e: *Env) Allocator {
        return e.arena.allocator();
    }

    /// `x`, or the test fails with the diagnostic.
    fn ok(e: *Env, x: anytype) !@typeInfo(@TypeOf(x)).error_union.payload {
        return x catch |err| {
            std.debug.print("unexpected {t}: {s}\n", .{ err, e.d.message() });
            return err;
        };
    }
};

fn expectErr(x: anytype) !void {
    if (x) |_| return error.TestExpectedError else |_| {}
}

fn sp(e: *Env, base: []const u8) !StorePath {
    return e.ok(StorePath.fromBaseName(base, &e.d));
}

fn unparse(e: *Env, drv: *const Derivation) ![]u8 {
    return e.ok(drv.unparseAlloc(e.a(), .{}, &e.d));
}

fn pathOf(e: *Env, drv: *const Derivation) !StorePath {
    const text = try unparse(e, drv);
    return e.ok(drv.drvPathFor(testing.allocator, text, &e.d));
}

/// Derivation equality: the name and everything the ATerm holds.
fn expectSameDrv(e: *Env, want: *const Derivation, got: *const Derivation) !void {
    try testing.expectEqualStrings(want.name, got.name);
    try testing.expectEqualStrings(try unparse(e, want), try unparse(e, got));
}

fn expectPath(want_base: []const u8, p: StorePath) !void {
    try testing.expectEqualStrings(want_base, p.baseName());
}

const no_loader: Loader = .{ .ctx = undefined, .loadFn = struct {
    fn load(_: *anyopaque, _: Allocator, drv_path: StorePath, _: *Diag) drv_mod.Error!Derivation {
        std.debug.panic("no input derivation to load, asked for {f}", .{&drv_path});
    }
}.load };

fn finalize(e: *Env, drv: *Derivation, loader: Loader) !void {
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    try drv_mod.finalizeInputAddressedOutputs(e.a(), drv, &cache, loader, &e.d);
}

fn hashModulo(e: *Env, drv: *const Derivation, mask: bool, loader: Loader) !drv_mod.DrvHash {
    var cache: DrvHashCache = .init(testing.allocator);
    defer cache.deinit();
    return e.ok(drv_mod.hashDerivationModulo(e.a(), drv, mask, &cache, loader, &e.d));
}

const Case = struct { file: []const u8, text: []const u8, name: []const u8 };

fn case(comptime file: []const u8, name: []const u8) Case {
    return .{ .file = file, .text = fixture(file), .name = name };
}

/// The name is what the `.json` next to each upstream `.drv` gives.
const upstream = [_]Case{
    case("simple-derivation.drv", "simple-derivation"),
    case("dyn-dep-derivation.drv", "dyn-dep-derivation"),
    case("ca-advanced-attributes.drv", "advanced-attributes"),
    case("ca-advanced-attributes-defaults.drv", "advanced-attributes-defaults"),
    case("ca-advanced-attributes-structured-attrs.drv", "advanced-attributes-structured-attrs"),
    case("ca-advanced-attributes-structured-attrs-defaults.drv", "advanced-attributes-structured-attrs-defaults"),
    case("ia-advanced-attributes.drv", "advanced-attributes"),
    case("ia-advanced-attributes-defaults.drv", "advanced-attributes-defaults"),
    case("ia-advanced-attributes-structured-attrs.drv", "advanced-attributes-structured-attrs"),
    case("ia-advanced-attributes-structured-attrs-defaults.drv", "advanced-attributes-structured-attrs-defaults"),
};

test "upstream drvs roundtrip byte-exact" {
    var e: Env = .init();
    defer e.deinit();
    for (upstream) |c| {
        errdefer std.debug.print("{s}\n", .{c.file});
        const drv = try e.ok(Derivation.parse(e.a(), c.text, c.name, &e.d));
        try testing.expectEqualStrings(c.text, try unparse(&e, &drv));
    }
}

test "upstream bad drvs are rejected" {
    var e: Env = .init();
    defer e.deinit();
    for ([_][]const u8{ fixture("bad-version.drv"), fixture("bad-old-version-dyn-deps.drv") }) |text|
        try expectErr(Derivation.parse(e.a(), text, "x", &e.d));
}

// Nix's parser benchmark data. Its hashes were blanked to `aaaa…`, which left
// the input derivations out of the order Nix prints, so it cannot roundtrip
// byte for byte; printing what was parsed must still be a fixpoint.
test "upstream bench drvs parse and reprint stably" {
    var e: Env = .init();
    defer e.deinit();
    for ([_]Case{ case("hello.drv", "hello-2.12.2"), case("firefox.drv", "firefox") }) |c| {
        const drv = try e.ok(Derivation.parse(e.a(), c.text, c.name, &e.d));
        const printed = try unparse(&e, &drv);
        const again = try e.ok(Derivation.parse(e.a(), printed, c.name, &e.d));
        try expectSameDrv(&e, &drv, &again);
        try testing.expectEqualStrings(printed, try unparse(&e, &again));
    }
}

// The input-addressed fixtures with no input derivations: their output paths
// are recomputed from nothing and must be the ones Nix wrote.
test "upstream input-addressed paths recompute" {
    var e: Env = .init();
    defer e.deinit();
    for ([_]Case{
        case("ia-advanced-attributes-defaults.drv", "advanced-attributes-defaults"),
        case("ia-advanced-attributes-structured-attrs-defaults.drv", "advanced-attributes-structured-attrs-defaults"),
    }) |c| {
        const original = try e.ok(Derivation.parse(e.a(), c.text, c.name, &e.d));
        try testing.expectEqual(0, original.input_drvs.len);
        var drv = try e.ok(Derivation.parse(e.a(), c.text, c.name, &e.d));
        for (drv.outputs) |*o| {
            o.output = .deferred;
            if (drv.envGet(o.name) != null) try drv.envSet(e.a(), o.name, "");
        }
        try e.ok(finalize(&e, &drv, no_loader));
        try expectSameDrv(&e, &original, &drv);
    }
}

/// A derivation with its outputs and env sorted by key.
fn simple(e: *Env, name: []const u8, outputs: []const NamedOutput, env: []const EnvVar) !Derivation {
    const outs = try e.a().dupe(NamedOutput, outputs);
    std.mem.sort(NamedOutput, outs, {}, struct {
        fn lt(_: void, x: NamedOutput, y: NamedOutput) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    var drv: Derivation = .{ .name = name, .outputs = outs, .platform = "x86_64-linux", .builder = "/bin/sh" };
    for (env) |v| try drv.envSet(e.a(), v.key, v.value);
    return drv;
}

fn withInputs(e: *Env, drv: *Derivation, deps: []const StorePath) !void {
    const inputs = try e.a().alloc(InputDrv, deps.len);
    for (deps, inputs) |p, *in| in.* = .{ .path = p, .node = .{ .outputs = &.{"out"} } };
    std.mem.sort(InputDrv, inputs, {}, struct {
        fn lt(_: void, x: InputDrv, y: InputDrv) bool {
            return StorePath.lessThan({}, x.path, y.path);
        }
    }.lt);
    drv.input_drvs = inputs;
}

// libstore-tests/derivation/invariants.cc: `fillInOutputPaths` on a deferred
// output, with the paths Nix computed in `data/derivation/invariants/*-post.json`.
test "upstream invariants fill in deferred" {
    const cases = [_]struct { name: []const u8, doc: []const u8, env_out: ?[]const u8, want: []const u8 }{
        .{
            .name = "filled-in-deferred-empty-env-var",
            .doc = "Fill in deferred output with empty env var",
            .env_out = "",
            .want = "bilpz1nq8qi9r3bzsp72n34yjgqg43ws-filled-in-deferred-empty-env-var",
        },
        .{
            .name = "filled-in-deferred-no-env-var",
            .doc = "Fill in deferred with missing env var",
            .env_out = null,
            .want = "wpk9qrgg77fyswhailap0gicgw98izx9-filled-in-deferred-no-env-var",
        },
    };
    for (cases) |c| {
        var e: Env = .init();
        defer e.deinit();
        var env: std.ArrayList(EnvVar) = .empty;
        try env.append(e.a(), .{ .key = "__doc", .value = c.doc });
        if (c.env_out) |v| try env.append(e.a(), .{ .key = "out", .value = v });
        var drv = try simple(&e, c.name, &.{.{ .name = "out", .output = .deferred }}, env.items);
        try e.ok(finalize(&e, &drv, no_loader));
        try expectPath(c.want, drv.output("out").?.output.input_addressed);
        const want_env = try std.fmt.allocPrint(e.a(), "/nix/store/{s}", .{c.want});
        try testing.expectEqualStrings(want_env, drv.envGet("out").?);
    }
}

test "upstream invariants input-addressed kept or rejected" {
    var e: Env = .init();
    defer e.deinit();
    const ok = "w4bk7hpyxzgy2gx8fsa8f952435pll3i-filled-in-already";
    var drv = try simple(&e, "filled-in-already", &.{.{ .name = "out", .output = .{ .input_addressed = try sp(&e, ok) } }}, &.{
        .{ .key = "__doc", .value = "Correct path stays unchanged" },
        .{ .key = "out", .value = "/nix/store/" ++ ok },
    });
    const before = try unparse(&e, &drv);
    try e.ok(finalize(&e, &drv, no_loader));
    try testing.expectEqualStrings(before, try unparse(&e, &drv));

    const wrong = "c015dhfh5l0lp6wxyvdn7bmwhbbr6hr9-wrong-name";
    var bad = try simple(&e, "bad-path", &.{.{ .name = "out", .output = .{ .input_addressed = try sp(&e, wrong) } }}, &.{
        .{ .key = "__doc", .value = "Wrong InputAddressed path throws error" },
        .{ .key = "out", .value = "/nix/store/" ++ wrong },
    });
    try expectErr(finalize(&e, &bad, no_loader));
}

/// invariants.cc:`makeCAFloatingDependency("dependency")`, which Nix writes to
/// `lg4c4b8r9hlczwprl6kgnzfd9mc1xmkk-dependency.drv`.
fn caFloatingDependency(e: *Env) !Derivation {
    return simple(e, "dependency", &.{.{ .name = "out", .output = .{ .ca_floating = .{ .method = .recursive, .algo = .sha256 } } }}, &.{
        .{ .key = "out", .value = "" },
    });
}

/// Loads `want` only, as `caFloatingDependency`.
const CaFloatingLoader = struct {
    e: *Env,
    want: ?StorePath,

    fn loader(l: *CaFloatingLoader) Loader {
        return .{ .ctx = l, .loadFn = load };
    }

    fn load(ctx: *anyopaque, _: Allocator, drv_path: StorePath, _: *Diag) drv_mod.Error!Derivation {
        const l: *CaFloatingLoader = @ptrCast(@alignCast(ctx));
        if (l.want) |w| std.debug.assert(w.eql(&drv_path));
        return caFloatingDependency(l.e) catch return error.OutOfMemory;
    }
};

test "upstream invariants ca floating dependency" {
    var e: Env = .init();
    defer e.deinit();
    const dep = try caFloatingDependency(&e);
    const dep_path = try sp(&e, "lg4c4b8r9hlczwprl6kgnzfd9mc1xmkk-dependency.drv");
    try expectPath(dep_path.baseName(), try pathOf(&e, &dep));

    var l: CaFloatingLoader = .{ .e = &e, .want = dep_path };
    const with_dep = struct {
        fn f(env: *Env, out: Output, doc: []const u8, p: StorePath) !Derivation {
            var drv = try simple(env, "depends-on-drv", &.{.{ .name = "out", .output = out }}, &.{
                .{ .key = "__doc", .value = doc },
                .{ .key = "out", .value = "" },
            });
            try withInputs(env, &drv, &.{p});
            return drv;
        }
    }.f;

    var drv = try with_dep(&e, .deferred, "Deferred stays deferred with CA dependencies", dep_path);
    const before = try unparse(&e, &drv);
    try e.ok(finalize(&e, &drv, l.loader()));
    try testing.expectEqualStrings(before, try unparse(&e, &drv));

    var bad = try with_dep(
        &e,
        .{ .input_addressed = try sp(&e, "c015dhfh5l0lp6wxyvdn7bmwhbbr6hr9-wrong-name") },
        "InputAddressed throws when should be deferred",
        dep_path,
    );
    try expectErr(finalize(&e, &bad, l.loader()));
}

// harmonia-store-aterm/tests/roundtrip.rs.
test "harmonia cases roundtrip" {
    const cases = [_]struct { input: []const u8, name: []const u8 }{
        // plain
        .{
            .input =
            \\Derive([("out","","","")],[],[],"x86_64-linux","/bin/sh",[],[("name","test")])
            ,
            .name = "test",
        },
        // recursive hash
        .{
            .input =
            \\Derive([("out","","r:sha256","")],[],[],"x86_64-linux","/bin/sh",[],[("name","test")])
            ,
            .name = "test",
        },
        // escapes
        .{
            .input =
            \\Derive([("out","","","")],[],[],"x86_64-linux","/bin/sh",[],[("msg","hello\nworld\t\"test\"\\end"),("name","test")])
            ,
            .name = "test",
        },
        // gnused
        .{
            .input =
            \\Derive([("info","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9-info","",""),("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9","","")],[("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bootstrap-tools.drv",["out"]),("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-stdenv-linux.drv",["out"])],["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-default-builder.sh"],"x86_64-linux","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bootstrap-tools/bin/bash",["-e","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-stdenv.sh"],[("name","gnused-4.9"),("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9"),("system","x86_64-linux")])
            ,
            .name = "gnused-4.9",
        },
        // fixed output
        .{
            .input =
            \\Derive([("out","/nix/store/6fr8dalasgpy0bpykhjq2b9q65lb4j8y-linux-6.16.tar.xz","sha256","1a4be2fe6b5246aa4ac8987a8a4af34c42a8dd7d08b46ab48516bcc1befbcd83")],[],[],"builtin","builtin:fetchurl",[],[("name","linux-6.16.tar.xz")])
            ,
            .name = "linux-6.16.tar.xz",
        },
    };
    var e: Env = .init();
    defer e.deinit();
    for (cases) |c| {
        const drv = try e.ok(Derivation.parse(e.a(), c.input, c.name, &e.d));
        try testing.expectEqualStrings(c.input, try unparse(&e, &drv));
    }
}

// derivations.cc:parseDerivationOutput only checks that a fixed output's path
// starts with `/`; unparse prints the path the content address gives.
test "fixed output path is recomputed, not trusted" {
    var e: Env = .init();
    defer e.deinit();
    const wrong =
        \\Derive([("out","/nix/store/00000000000000000000000000000000-linux-6.16.tar.xz","sha256","1a4be2fe6b5246aa4ac8987a8a4af34c42a8dd7d08b46ab48516bcc1befbcd83")],[],[],"builtin","builtin:fetchurl",[],[("name","linux-6.16.tar.xz")])
    ;
    const drv = try e.ok(Derivation.parse(e.a(), wrong, "linux-6.16.tar.xz", &e.d));
    const want = try std.mem.replaceOwned(u8, e.a(), wrong, "00000000000000000000000000000000", "6fr8dalasgpy0bpykhjq2b9q65lb4j8y");
    try testing.expectEqualStrings(want, try unparse(&e, &drv));
}

// harmonia-store-aterm/src/parser.rs and raw_output.rs: errors, not panics.
test "malformed aterm is an error" {
    var e: Env = .init();
    defer e.deinit();
    for ([_][]const u8{
        "",
        "Derive([",
        "Derive(x",
        \\Derive([("out","","r:sha256","abc")],[],[],"x86_64-linux","/bin/sh",[],[])
        ,
        \\Derive([("out","/nix/store/00000000000000000000000000000000-x","sha256","abc")],[],[],"x86_64-linux","/bin/sh",[],[])
        ,
    }) |input| {
        errdefer std.debug.print("accepted: {s}\n", .{input});
        try expectErr(Derivation.parse(e.a(), input, "x", &e.d));
    }
}

fn fetch(e: *Env, url: []const u8) !Derivation {
    const hash = try e.ok(Hash.parseNonSriUnprefixed("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", .sha256, &e.d));
    var drv = try simple(e, "dep-1.0", &.{.{ .name = "out", .output = .{ .fixed = .{ .method = .flat, .hash = hash } } }}, &.{
        .{ .key = "url", .value = url },
    });
    drv.builder = "builtin:fetchurl";
    return drv;
}

fn on(e: *Env, deps: []const StorePath) !Derivation {
    var drv = try simple(e, "app-1.0", &.{.{ .name = "out", .output = .deferred }}, &.{.{ .key = "out", .value = "" }});
    try withInputs(e, &drv, deps);
    return drv;
}

/// Loads from a fixed table of derivations by path.
const MapLoader = struct {
    paths: []const StorePath,
    drvs: []const Derivation,

    fn loader(l: *MapLoader) Loader {
        return .{ .ctx = l, .loadFn = load };
    }

    fn load(ctx: *anyopaque, _: Allocator, drv_path: StorePath, _: *Diag) drv_mod.Error!Derivation {
        const l: *MapLoader = @ptrCast(@alignCast(ctx));
        for (l.paths, l.drvs) |p, drv| if (p.eql(&drv_path)) return drv;
        std.debug.panic("no derivation {f}", .{&drv_path});
    }
};

// harmonia-store-aterm/src/hash_modulo.rs `fixed_output_provenance_hidden`:
// the url of a fixed-output input does not reach the output path downstream.
// Depending on both copies is the same as depending on one, because their
// modulo hashes collide and hashDerivationModulo merges the output sets.
test "fixed-output inputs hide their provenance" {
    var e: Env = .init();
    defer e.deinit();
    const a = try fetch(&e, "https://a.example/t");
    const b = try fetch(&e, "https://b.example/t");
    const pa = try pathOf(&e, &a);
    const pb = try pathOf(&e, &b);
    try testing.expect(!pa.eql(&pb));
    var l: MapLoader = .{ .paths = &.{ pa, pb }, .drvs = &.{ a, b } };
    const outPath = struct {
        fn f(env: *Env, drv: *Derivation, loader: Loader) !StorePath {
            try env.ok(finalize(env, drv, loader));
            return drv.output("out").?.output.input_addressed;
        }
    }.f;
    var on_a = try on(&e, &.{pa});
    const via_a = try outPath(&e, &on_a, l.loader());
    var on_b = try on(&e, &.{pb});
    try expectPath(via_a.baseName(), try outPath(&e, &on_b, l.loader()));
    var on_ab = try on(&e, &.{ pa, pb });
    try expectPath(via_a.baseName(), try outPath(&e, &on_ab, l.loader()));
}

// harmonia-store-aterm/src/hash_modulo.rs `floating_ca_is_deferred` and
// `deferred_input_defers`.
test "floating ca defers itself and downstream" {
    var e: Env = .init();
    defer e.deinit();
    const dep = try caFloatingDependency(&e);
    try testing.expectEqual(.deferred, (try hashModulo(&e, &dep, false, no_loader)).kind);

    const dep_path = try pathOf(&e, &dep);
    var l: CaFloatingLoader = .{ .e = &e, .want = null };
    const downstream = try on(&e, &.{dep_path});
    try testing.expectEqual(.deferred, (try hashModulo(&e, &downstream, true, l.loader())).kind);
}

// harmonia-store-aterm/src/hash_modulo.rs `identity_and_masked_hashes_differ`.
test "masked and unmasked hashes differ once filled" {
    var e: Env = .init();
    defer e.deinit();
    var drv = try on(&e, &.{});
    try e.ok(finalize(&e, &drv, no_loader));
    const masked = try hashModulo(&e, &drv, true, no_loader);
    const identity = try hashModulo(&e, &drv, false, no_loader);
    try testing.expect(!masked.get("out").?.eql(identity.get("out").?));
}

// harmonia-store-aterm/tests/roundtrip.rs `roundtrip_non_utf8_bytes`: an ATerm
// string is bytes, and an arg or an env value that is not UTF-8 survives.
test "bytes that are not UTF-8 roundtrip" {
    var e: Env = .init();
    defer e.deinit();
    const input = "Derive([(\"out\",\"\",\"\",\"\")],[],[],\"x86_64-linux\",\"/bin/sh\",[\"a\xc8\x82b\"],[(\"name\",\"test\"),(\"v\",\"\xc8\")])";
    const drv = try e.ok(Derivation.parse(e.a(), input, "test", &e.d));
    try testing.expectEqual(1, drv.args.len);
    try testing.expectEqualSlices(u8, "a\xc8\x82b", drv.args[0]);
    const v = drv.envGet("v").?;
    try testing.expectEqualSlices(u8, "\xc8", v);
    // the value stays bytes: it is not UTF-8
    try testing.expect(!std.unicode.utf8ValidateSlice(v));
    try testing.expectEqualSlices(u8, input, try unparse(&e, &drv));
}
