//! `derivationStrict` and the derivation path pipeline (primops.cc:
//! derivationStrictInternal): attrs -> `Derivation` -> output paths ->
//! drvPath. Also `placeholder`, `outputOf` and `import` of a `.drv` store
//! path.

const std = @import("std");
const Scratch = @import("../Scratch.zig");
const Allocator = std.mem.Allocator;
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const lint = @import("../lint.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const Ctx = value.Ctx;
const Sym = @import("../syntax/symbol.zig").Sym;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const print = @import("../eval/print.zig");
const import_ = @import("../eval/import.zig");
const drv_mod = @import("../store/drv.zig");
const Derivation = drv_mod.Derivation;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const IngestionMethod = path_mod.IngestionMethod;
const store_json = @import("../store/json.zig");

pub const ops = [_]Op{
    .{ .name = "derivationStrict", .arity = 1, .f = derivationStrict },
    .{ .name = "placeholder", .arity = 1, .f = placeholder },
    .{ .name = "outputOf", .arity = 2, .f = outputOf },
};

/// What later derivations need about one this evaluation created or read:
/// its output names and the references of its `.drv` (for `=drv` context
/// closures). Its `hashDerivationModulo` lives in `State.cache`, so the full
/// `Derivation` is not kept.
pub const Info = struct {
    /// Sorted.
    outputs: []const []const u8,
    /// Full store paths: the input sources and the input derivations.
    references: []const []const u8,
    /// For a derivation this evaluation created, what each output's string
    /// is (`outputs[i]`'s path or downstream placeholder).
    rendered: ?[]const []const u8 = null,
    /// The ATerm, kept only for a derivation whose output is itself a `.drv`
    /// (`builtins.outputOf` reads it back; nothing is written to the store).
    aterm: ?[]const u8 = null,
    /// Where the derivation was defined. `derivation` wraps
    /// `derivationStrict`, so a normal call's own position is inside
    /// `«derivation-internal»`; the `name` attribute's value is used instead,
    /// the position Nix names in "whose name attribute is located at".
    site: Pos = .none,
    /// The attribute path a cli walk reached it by; the first walk wins, as
    /// `getDerivations` reports the first path.
    attr: ?[]const u8 = null,
};

/// Records the attribute path a cli walk reached `drv_base` by.
pub fn setAttr(ev: *Evaluator, drv_base: []const u8, attr: []const u8) Error!void {
    if (attr.len == 0) return;
    ev.shared.drv_lock.lock(ev);
    defer ev.shared.drv_lock.unlock(ev);
    const i = ev.shared.drv.table.getPtr(drv_base) orelse return;
    if (i.attr == null) i.attr = try ev.local.arena.dupe(u8, attr);
}

/// Per-evaluator derivation state (derivations.cc:drvHashes plus the
/// derivations this evaluation created). Everything but the maps lives in
/// the evaluator's arena.
pub const State = struct {
    cache: ?drv_mod.DrvHashCache = null,
    /// By `.drv` base name.
    table: std.StringHashMapUnmanaged(Info) = .empty,
    syms: ?Syms = null,
    imported_drv_fn: ?Value = null,
    nr_derivations: u64 = 0,

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.cache) |*c| c.deinit();
        s.table.deinit(gpa);
    }

    pub fn hashCache(s: *State, gpa: Allocator) *drv_mod.DrvHashCache {
        if (s.cache == null) s.cache = .init(gpa);
        return &s.cache.?;
    }
};

const Syms = struct {
    args: Sym,
    builder: Sym,
    system: Sym,
    outputHash: Sym,
    outputHashAlgo: Sym,
    outputHashMode: Sym,
    outputs: Sym,
    __structuredAttrs: Sym,
    requiredSystemFeatures: Sym,
    __ignoreNulls: Sym,
    __contentAddressed: Sym,
    __impure: Sym,
    __json: Sym,
};

fn syms(ev: *Evaluator) Error!Syms {
    ev.shared.drv_lock.lock(ev);
    defer ev.shared.drv_lock.unlock(ev);
    if (ev.shared.drv.syms) |s| return s;
    var s: Syms = undefined;
    inline for (@typeInfo(Syms).@"struct".field_names) |n| @field(s, n) = try ev.sym(n);
    ev.shared.drv.syms = s;
    return s;
}

/// A store-layer error as an evaluation error at `pos`.
fn drvFail(ev: *Evaluator, d: *const Diag, e: anyerror, pos: Pos) Error {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    return ev.fail(.eval, pos, "{s}", .{d.message()});
}

/// `--dump-drvs`: one derivation's ATerm as `dir/base`.
fn dumpDrv(ev: *Evaluator, dir: []const u8, base: []const u8, text: []const u8, pos: Pos) Error!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, base }) catch return ev.fail(.io, pos, "writing '{s}/{s}': File name too long", .{ dir, base });
    std.Io.Dir.cwd().writeFile(ev.io, .{ .sub_path = file, .data = text }) catch |e|
        return ev.fail(.io, pos, "writing '{s}': {s}", .{ file, @import("../errors.zig").ioText(e) });
}

fn checkUtf8(ev: *Evaluator, s: []const u8, pos: Pos) Error![]const u8 {
    if (!std.unicode.utf8ValidateSlice(s)) return ev.fail(.eval, pos, "string is not valid UTF-8", .{});
    return s;
}

fn parseStorePath(ev: *Evaluator, p: []const u8, pos: Pos) Error!StorePath {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    return StorePath.parse(p, &d) catch |e| drvFail(ev, &d, e, pos);
}

/// The full path of `p` in the arena.
fn pathString(ev: *Evaluator, p: *const StorePath) Error![]const u8 {
    var buf: [4096]u8 = undefined;
    return ev.local.arena.dupe(u8, p.print(&buf));
}

const Built = struct {
    /// The output names of the dynamic derivation layers, outermost first.
    layers: []const []const u8,
    /// The `.drv` at the bottom.
    root: []const u8,
};

/// Takes the path of a `built` context element apart.
fn splitBuilt(a: Allocator, p: []const u8) Allocator.Error!Built {
    var l: std.ArrayList([]const u8) = .empty;
    var rest = p;
    while (std.mem.indexOfScalar(u8, rest, '!')) |i| {
        try l.append(a, rest[0..i]);
        rest = rest[i + 1 ..];
    }
    return .{ .layers = l.items, .root = rest };
}

/// Reads a `.drv` for `hashDerivationModulo`: one this evaluation kept the
/// ATerm of, else the one in the store. The derivations this evaluation
/// created are in the hash cache already, so this runs only for the rest.
const TableLoader = struct {
    ev: *Evaluator,

    fn loader(t: *TableLoader) drv_mod.Loader {
        return .{ .ctx = t, .loadFn = load };
    }

    fn load(ctx: *anyopaque, arena: Allocator, drv_path: StorePath, d: *Diag) drv_mod.Error!Derivation {
        const t: *TableLoader = @ptrCast(@alignCast(ctx));
        return loadDrv(t.ev, arena, drv_path, d);
    }
};

/// The derivation as this evaluation produced it, else from the store.
fn loadDrv(ev: *Evaluator, arena: Allocator, p: StorePath, d: *Diag) drv_mod.Error!Derivation {
    ev.shared.drv_lock.lock(ev);
    defer ev.shared.drv_lock.unlock(ev);
    if (ev.shared.drv.table.get(p.baseName())) |i| if (i.aterm) |text|
        return Derivation.parse(arena, text, try Derivation.nameFromPath(&p, d), d);
    return loadDrvTraced(ev, arena, p, d);
}

/// A `.drv` from the store, whose bytes go into the read set when the
/// tracing cache is on.
fn loadDrvTraced(ev: *Evaluator, arena: Allocator, p: StorePath, d: *Diag) drv_mod.Error!Derivation {
    const t = ev.trace();
    if (!t.isOn()) return drv_mod.loadDerivationFromStore(ev.io, arena, p, d);
    const name = try Derivation.nameFromPath(&p, d);
    var buf: [4096]u8 = undefined;
    const full = p.print(&buf);
    const f = std.Io.Dir.cwd().openFile(ev.io, full, .{}) catch |e|
        return d.fail(error.BadDerivation, "cannot read derivation '{s}': {t}", .{ full, e });
    defer f.close(ev.io);
    const meta = @import("../sys/fs.zig").fstat(f.handle) catch |e|
        return d.fail(error.BadDerivation, "cannot read derivation '{s}': {t}", .{ full, e });
    var rbuf: [4096]u8 = undefined;
    var r = f.readerStreaming(ev.io, &rbuf);
    const text = r.interface.allocRemaining(arena, .unlimited) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return d.fail(error.BadDerivation, "cannot read derivation '{s}': {t}", .{ full, e }),
    };
    t.file(full, meta, text);
    return Derivation.parse(arena, text, name, d);
}

/// Mirrors primops.cc:prim_derivationStrict.
fn derivationStrict(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const attrs = try ev.forceAttrs(args[0], pos, "while evaluating the argument passed to builtins.derivationStrict");
    const name_attr = attrs.get(ev.s.name) orelse {
        const e = ev.fail(.missing_attr, pos, "attribute 'name' missing", .{});
        return ev.addTrace(e, pos, "in the attrset passed as argument to builtins.derivationStrict", .{});
    };
    const drv_name_raw = ev.forceStringNoCtx(name_attr.cell.get(), pos, "while evaluating the `name` attribute passed to builtins.derivationStrict") catch |e|
        return ev.addTrace(e, name_attr.pos, "while evaluating the derivation attribute 'name'", .{});
    const drv_name = try checkUtf8(ev, drv_name_raw, pos);
    const s = try syms(ev);
    return derivationStrictInternal(ev, drv_name, attrs, pos, name_attr.pos, &s) catch |e|
        ev.addTrace(e, .none, "while evaluating derivation '{s}'\n  whose name attribute is located at {f}", .{ drv_name, ev.files.at(name_attr.pos) });
}

/// A node of `input_drvs` under construction.
const MNode = struct {
    outputs: std.ArrayList([]const u8) = .empty,
    children: std.ArrayList(MChild) = .empty,

    fn child(n: *MNode, a: Allocator, name: []const u8) Allocator.Error!*MNode {
        for (n.children.items) |c| if (std.mem.eql(u8, c.name, name)) return c.node;
        const c = try a.create(MNode);
        c.* = .{};
        try n.children.append(a, .{ .name = name, .node = c });
        return c;
    }

    fn addOutput(n: *MNode, a: Allocator, o: []const u8) Allocator.Error!void {
        for (n.outputs.items) |x| if (std.mem.eql(u8, x, o)) return;
        try n.outputs.append(a, o);
    }

    fn freeze(n: *const MNode, a: Allocator) Allocator.Error!drv_mod.InputNode {
        const outs = try a.dupe([]const u8, n.outputs.items);
        std.mem.sort([]const u8, outs, {}, strLess);
        const kids = try a.alloc(drv_mod.InputNode.Child, n.children.items.len);
        for (n.children.items, kids) |c, *k| k.* = .{ .name = c.name, .node = try c.node.freeze(a) };
        std.mem.sort(drv_mod.InputNode.Child, kids, {}, struct {
            fn lt(_: void, x: drv_mod.InputNode.Child, y: drv_mod.InputNode.Child) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        return .{ .outputs = outs, .children = kids };
    }
};

const MChild = struct { name: []const u8, node: *MNode };

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// derivations.hh:drvFeatureBuilderRpcV0.
const builder_rpc_v0 = "builder-rpc-v0";

/// primops.cc reads `requiredSystemFeatures` only with this feature on;
/// iets's own commands have every feature.
fn dynamicDerivations(ev: *const Evaluator) bool {
    const s = ev.config.session orelse return true;
    return !s.log.isClassic() or s.xpOn("dynamic-derivations");
}
const whitespace = " \t\n\r";

const Builder = struct {
    ev: *Evaluator,
    s: *const Syms,
    /// The temporary arena the derivation is built in.
    a: Allocator,
    drv: Derivation,
    context: std.ArrayList(Ctx) = .empty,
    /// The string form of the attribute being processed, its capacity kept
    /// from one attribute to the next.
    scratch: std.ArrayList(u8) = .empty,
    ignore_nulls: bool,
    content_addressed: bool = false,
    output_hash: ?[]const u8 = null,
    output_hash_algo: ?hash_mod.Algo = null,
    ingestion_method: ?IngestionMethod = null,
    /// Sorted and unique once `finishOutputs` ran.
    outputs: std.ArrayList([]const u8) = .empty,
    /// The structured-attrs JSON object under construction, when
    /// `__structuredAttrs = true`.
    json: ?std.Io.Writer.Allocating = null,
    json_empty: bool = true,
    /// `requiredSystemFeatures` holds `builder-rpc-v0`: the builder
    /// registers its outputs, so the environment names none.
    submits_outputs: bool = false,
    /// The derivation's own site for `drv-bool-null` and `drv-list`
    /// (`lint.coerce.drvOwner`); null keeps both silent.
    lint_owner: ?Pos = null,
    /// `lint.coerce.drvFallback`, found when the first finding needs it.
    lint_fallback: ?Pos = null,
    attrs: *value.Attrs,
    pos: Pos,
    name_pos: Pos,

    fn fallback(b: *Builder) Pos {
        if (b.lint_fallback == null) b.lint_fallback = lint.coerce.drvFallback(b.ev, b.attrs, b.pos, b.name_pos);
        return b.lint_fallback.?;
    }

    /// Mirrors the `handleHashMode` lambda.
    fn handleHashMode(b: *Builder, s: []const u8, pos: Pos) Error!void {
        if (IngestionMethod.parse(s)) |m| {
            b.ingestion_method = m;
            return;
        }
        if (std.mem.eql(u8, s, "git"))
            return b.ev.fail(.eval, pos, "outputHashMode '{s}' is not supported (experimental feature)", .{s});
        return b.ev.fail(.eval, pos, "invalid value '{s}' for 'outputHashMode' attribute", .{s});
    }

    /// One name of the `handleOutputs` lambda.
    fn addOutput(b: *Builder, j: []const u8, pos: Pos) Error!void {
        for (b.outputs.items) |o| if (std.mem.eql(u8, o, j))
            return b.ev.fail(.eval, pos, "duplicate derivation output '{s}'", .{j});
        if (std.mem.eql(u8, j, "drvPath"))
            return b.ev.fail(.eval, pos, "invalid derivation output name 'drvPath'", .{});
        try b.outputs.append(b.a, j);
    }

    fn finishOutputs(b: *Builder, pos: Pos) Error!void {
        if (b.outputs.items.len == 0)
            return b.ev.fail(.eval, pos, "derivation cannot have an empty set of outputs", .{});
        std.mem.sort([]const u8, b.outputs.items, {}, strLess);
    }

    fn hasOnlyOut(b: *const Builder) bool {
        return b.outputs.items.len == 1 and std.mem.eql(u8, b.outputs.items[0], "out");
    }
};

fn jsonErr(e: anyerror) Error {
    return switch (e) {
        error.EvalFailed => error.EvalFailed,
        else => error.OutOfMemory,
    };
}

/// One iteration of the attribute loop in derivationStrictInternal.
/// Attributes arrive in lexicographic order, so appending to `drv.env`
/// keeps it sorted.
fn processAttr(b: *Builder, sym: Sym, key: []const u8, w: Value, pos: Pos, attr_pos: Pos) Error!void {
    const ev = b.ev;
    const s = b.s;
    if (b.ignore_nulls and try ev.force(w) == .null) return;
    if (sym == s.__contentAddressed) {
        if (try ev.forceBool(w, pos, "")) b.content_addressed = true;
        return;
    }
    if (sym == s.__impure) {
        if (try ev.forceBool(w, pos, ""))
            return ev.fail(.eval, pos, "impure derivations are not supported (experimental feature)", .{});
        return;
    }
    const scratch = &b.scratch;
    scratch.clearRetainingCapacity();
    if (sym == s.args) {
        const l = try ev.forceList(w, pos, "");
        var args: std.ArrayList([]const u8) = .empty;
        for (l.cells()) |*c| {
            scratch.clearRetainingCapacity();
            try ev.coerceToString(c.get(), scratch, &b.context, attr_pos, "while evaluating an element of the argument list", .{ .coerce_more = true });
            try args.append(b.a, try b.a.dupe(u8, scratch.items));
        }
        b.drv.args = args.items;
        return;
    }
    if (b.json) |*json| {
        if (sym == s.__structuredAttrs) return;
        const jw = &json.writer;
        if (!b.json_empty) jw.writeByte(',') catch return error.OutOfMemory;
        b.json_empty = false;
        print.writeJsonString(ev, jw, key) catch |e| return jsonErr(e);
        jw.writeByte(':') catch return error.OutOfMemory;
        print.writeJson(ev, jw, w, &b.context, true, pos) catch |e| return jsonErr(e);
        if (sym == s.builder) {
            const st = try ev.forceString(w, pos, "");
            try b.context.appendSlice(ev.gpa, st.context());
            b.drv.builder = try checkUtf8(ev, st.bytes(), pos);
        } else if (sym == s.system) {
            b.drv.platform = try checkUtf8(ev, try ev.forceStringNoCtx(w, pos, ""), pos);
        } else if (sym == s.outputHash) {
            b.output_hash = try checkUtf8(ev, try ev.forceStringNoCtx(w, pos, ""), pos);
        } else if (sym == s.outputHashAlgo) {
            b.output_hash_algo = hash_mod.Algo.parse(try checkUtf8(ev, try ev.forceStringNoCtx(w, pos, ""), pos));
        } else if (sym == s.outputHashMode) {
            try b.handleHashMode(try checkUtf8(ev, try ev.forceStringNoCtx(w, pos, ""), pos), pos);
        } else if (sym == s.outputs) {
            const l = try ev.forceList(w, pos, "");
            b.outputs.clearRetainingCapacity();
            for (l.cells()) |*c| try b.addOutput(try checkUtf8(ev, try ev.forceStringNoCtx(c.get(), pos, ""), pos), pos);
            try b.finishOutputs(pos);
        } else if (sym == s.requiredSystemFeatures and dynamicDerivations(ev)) {
            const l = try ev.forceList(w, pos, "");
            for (l.cells()) |*c| {
                const st = try ev.forceString(c.get(), pos, "");
                if (std.mem.eql(u8, st.bytes(), builder_rpc_v0)) {
                    b.submits_outputs = true;
                    break;
                }
            }
        }
        return;
    }
    if (b.lint_owner) |owner| {
        const forced = try ev.force(w);
        try lint.coerce.drvValue(ev, key, forced, lint.coerce.drvAttrPos(ev, attr_pos, owner));
    }
    // the attribute's own position, so a coercion error names the binding
    try ev.coerceToString(w, scratch, &b.context, attr_pos, "", .{ .coerce_more = true });
    const raw = try b.a.dupe(u8, scratch.items);
    const is_text = sym == s.__json or sym == s.builder or sym == s.system or sym == s.outputHash or
        sym == s.outputHashAlgo or sym == s.outputHashMode or sym == s.outputs;
    if (sym == s.requiredSystemFeatures and dynamicDerivations(ev)) {
        var it = std.mem.splitAny(u8, raw, whitespace);
        while (it.next()) |f| if (std.mem.eql(u8, f, builder_rpc_v0)) {
            b.submits_outputs = true;
        };
    }
    if (!is_text) {
        try b.drv.env.append(b.a, .{ .key = key, .value = raw });
        return;
    }
    const st = try checkUtf8(ev, raw, pos);
    if (sym == s.__json) {
        try ev.effect("warning: In derivation '{s}': setting structured attributes via '__json' is deprecated, and may be disallowed in future versions of Nix. Set '__structuredAttrs = true' instead.", .{b.drv.name});
        var d: Diag = .init(ev.gpa);
        defer d.deinit();
        b.drv.structured_attrs = store_json.normaliseStructuredAttrs(b.a, st, &d) catch |e| return drvFail(ev, &d, e, .none);
        return;
    }
    if (sym == s.builder) {
        b.drv.builder = st;
    } else if (sym == s.system) {
        b.drv.platform = st;
    } else if (sym == s.outputHash) {
        b.output_hash = st;
    } else if (sym == s.outputHashAlgo) {
        b.output_hash_algo = hash_mod.Algo.parse(st);
    } else if (sym == s.outputHashMode) {
        try b.handleHashMode(st, pos);
    } else if (sym == s.outputs) {
        b.outputs.clearRetainingCapacity();
        var it = std.mem.tokenizeAny(u8, st, whitespace);
        while (it.next()) |t| try b.addOutput(t, pos);
        try b.finishOutputs(pos);
    }
    try b.drv.env.append(b.a, .{ .key = key, .value = st });
}

/// Mirrors primops.cc:derivationStrictInternal.
fn derivationStrictInternal(ev: *Evaluator, drv_name: []const u8, attrs: *value.Attrs, pos: Pos, name_pos: Pos, s: *const Syms) Error!Value {
    if (path_mod.nameProblem(drv_name)) |p|
        return ev.fail(.eval, pos, "invalid derivation name: {f}. Please pass a different 'name'.", .{p});
    const json_mode = if (attrs.get(s.__structuredAttrs)) |a|
        try ev.forceBool(a.cell.get(), pos, "while evaluating the `__structuredAttrs` attribute passed to builtins.derivationStrict")
    else
        false;
    const ignore_nulls = if (attrs.get(s.__ignoreNulls)) |a|
        try ev.forceBool(a.cell.get(), pos, "while evaluating the `__ignoreNulls` attribute passed to builtins.derivationStrict")
    else
        false;

    // Single-owner: std's arena pays an atomic on every allocation.
    var tmp: Scratch = .init(ev.gpa);
    defer tmp.deinit();
    const a = tmp.allocator();
    var b: Builder = .{
        .ev = ev,
        .s = s,
        .a = a,
        .drv = .{ .name = drv_name },
        .ignore_nulls = ignore_nulls,
        .attrs = attrs,
        .pos = pos,
        .name_pos = name_pos,
    };
    if (ev.lintOn(.drv_bool_null) or ev.lintOn(.drv_list)) {
        const builder_pos = if (attrs.get(s.builder)) |x| x.pos else .none;
        b.lint_owner = lint.coerce.drvOwner(ev, pos, builder_pos);
    }
    defer b.context.deinit(ev.gpa);
    defer b.scratch.deinit(ev.gpa);
    try b.outputs.append(a, "out");
    if (json_mode) {
        b.json = .init(a);
        b.json.?.writer.writeByte('{') catch return error.OutOfMemory;
    }

    // Every attribute is coerced next: let the helpers start on them.
    ev.offerAttrsCoerce(attrs);
    const sorted = try print.lexicographic(ev, attrs);
    defer ev.gpa.free(sorted);
    for (sorted) |attr| {
        if (attr.sym == s.__ignoreNulls) continue;
        const key = try checkUtf8(ev, ev.interner.name(attr.sym), pos);
        const before = b.context.items.len;
        processAttr(&b, attr.sym, key, attr.cell.get(), pos, attr.pos) catch |e|
            return ev.addTrace(e, attr.pos, "while evaluating attribute '{s}' of derivation '{s}'", .{ key, drv_name });
        const added = b.context.items[before..];
        for (added) |c| if (!c.isStore()) {
            const site = lint.coerce.drvAttrPos(ev, attr.pos, b.fallback());
            try lint.purity.marksInDrv(ev, drv_name, key, added, site, attr.pos);
            break;
        };
    }

    const drv = &b.drv;
    if (b.json) |*json| {
        json.writer.writeByte('}') catch return error.OutOfMemory;
        drv.structured_attrs = json.written();
    }

    // the context, sorted and unique, as Nix's `NixStringContext` set: the
    // `=drv` elements come before the `!out!drv` ones
    const ctx = b.context.items;
    std.sort.pdq(Ctx, ctx, {}, Ctx.lessThan);
    var srcs: std.ArrayList(StorePath) = .empty;
    const Root = struct { path: StorePath, node: *MNode };
    var roots: std.StringArrayHashMapUnmanaged(Root) = .empty;
    for (ctx, 0..) |c, ci| {
        if (ci > 0 and c.order(ctx[ci - 1]) == .eq) continue;
        switch (c.kind) {
            .impure_path, .impure_meta => {},
            .opaque_path => try srcs.append(a, try parseStorePath(ev, c.path, pos)),
            .built => {
                // derived-path-map.hh:DerivedPathMap::ensureSlot: one child per
                // layer, from the `.drv` at the bottom outwards, and the output
                // is taken of the node the last layer reaches
                const sb = try splitBuilt(a, c.path);
                const gop = try roots.getOrPut(a, sb.root);
                if (!gop.found_existing) {
                    const n = try a.create(MNode);
                    n.* = .{};
                    gop.value_ptr.* = .{ .path = try parseStorePath(ev, sb.root, pos), .node = n };
                }
                var node = gop.value_ptr.node;
                var i = sb.layers.len;
                while (i > 0) {
                    i -= 1;
                    node = try node.child(a, try checkUtf8(ev, sb.layers[i], pos));
                }
                try node.addOutput(a, try checkUtf8(ev, c.output, pos));
            },
            .drv_deep => {
                const closure = try drvClosure(ev, a, c.path, pos);
                for (closure) |j| {
                    try srcs.append(a, try parseStorePath(ev, j.path, pos));
                    const outs = j.outputs orelse continue;
                    // a map insert: it replaces what the slot held
                    const n = try a.create(MNode);
                    n.* = .{};
                    try n.outputs.appendSlice(a, outs);
                    const gop = try roots.getOrPut(a, j.path);
                    if (!gop.found_existing) gop.value_ptr.path = try parseStorePath(ev, j.path, pos);
                    gop.value_ptr.node = n;
                }
            },
        }
    }
    drv.input_srcs = path_mod.sortUnique(srcs.items);
    const input_drvs = try a.alloc(drv_mod.InputDrv, roots.count());
    for (roots.values(), input_drvs) |r, *o| o.* = .{ .path = r.path, .node = try r.node.freeze(a) };
    std.mem.sort(drv_mod.InputDrv, input_drvs, {}, struct {
        fn lt(_: void, x: drv_mod.InputDrv, y: drv_mod.InputDrv) bool {
            return x.path.order(&y.path) == .lt;
        }
    }.lt);
    drv.input_drvs = input_drvs;

    if (drv.builder.len == 0) return ev.fail(.eval, pos, "required attribute 'builder' missing", .{});
    if (drv.platform.len == 0) return ev.fail(.eval, pos, "required attribute 'system' missing", .{});
    // Nix writes the system without escapes (printUnquotedString), so these
    // give a .drv it cannot read back, or reads as another derivation; Nix
    // fails on them only after writing it. nix-conformance:
    // nix-bugs/drv-system-quote
    if (std.mem.indexOfAny(u8, drv.platform, "\"\\\n\r\t")) |i| {
        const shown = switch (drv.platform[i]) {
            '"' => "'\"'",
            '\\' => "'\\\\'",
            '\n' => "'\\n'",
            '\r' => "'\\r'",
            else => "'\\t'",
        };
        return ev.fail(.eval, pos, "derivation '{s}': the system holds {s}, which a .drv cannot hold", .{ drv_name, shown });
    }
    // a text-addressed single `out` is a derivation that produces a `.drv`
    if (std.mem.endsWith(u8, drv_name, path_mod.drv_extension) and !(b.ingestion_method == .text and b.hasOnlyOut()))
        return ev.fail(.eval, pos, "derivation names are allowed to end in '" ++ path_mod.drv_extension ++ "' only if they produce a single derivation file", .{});

    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    var tl: TableLoader = .{ .ev = ev };
    const loader = tl.loader();
    // Paths and hashes only from here on, nothing evaluated. The hash cache
    // is shared: its lock is held for the inputs' part of the modulo hash
    // and for the insert, never while hashing.
    const cache = blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        break :blk ev.shared.drv.hashCache(ev.gpa);
    };
    var modulo: ?drv_mod.ModuloInputs = null;
    const out_names = b.outputs.items;
    const outputs = try a.alloc(drv_mod.NamedOutput, out_names.len);
    drv.outputs = outputs;
    if (b.output_hash) |h| {
        if (!b.hasOnlyOut())
            return ev.fail(.eval, pos, "multiple outputs are not supported in fixed-output derivations", .{});
        const hash = if (h.len == 0) blk: {
            const algo = b.output_hash_algo orelse
                return ev.fail(.eval, pos, "empty hash requires explicit hash algorithm", .{});
            const zeros: [64]u8 = @splat(0);
            const zero = Hash.raw(algo, zeros[0..algo.size()]);
            var buf: [Hash.max_string_len]u8 = undefined;
            try ev.effect("warning: found empty hash, assuming '{s}'", .{zero.print(&buf, .sri, true)});
            break :blk zero;
        } else Hash.parseAny(h, b.output_hash_algo, &d) catch |e| return drvFail(ev, &d, e, pos);
        const method = b.ingestion_method orelse .flat;
        if (ev.lintOn(.fod)) {
            const mode = switch (method) {
                .flat => "flat",
                .recursive => "recursive",
                .text => "text",
            };
            const site = lint.coerce.drvAttrPos(ev, name_pos, b.fallback());
            try lint.purity.fod(ev, drv_name, mode, hash.algo.name(), site);
        }
        outputs[0] = .{ .name = "out", .output = .{ .fixed = .{ .method = method, .hash = hash } } };
        const p = path_mod.makeFixedOutputPathFor(method, hash, drv_name, "out", &d) catch |e| return drvFail(ev, &d, e, pos);
        if (!b.submits_outputs) {
            var buf: [4096]u8 = undefined;
            try drv.envSet(a, "out", try a.dupe(u8, p.print(&buf)));
        }
    } else if (b.content_addressed) {
        const algo = b.output_hash_algo orelse .sha256;
        const method = b.ingestion_method orelse .recursive;
        for (out_names, outputs) |o, *no| {
            if (!b.submits_outputs) {
                const ph = path_mod.hashPlaceholder(o);
                try drv.envSet(a, o, try a.dupe(u8, &ph));
            }
            no.* = .{ .name = o, .output = .{ .ca_floating = .{ .method = method, .algo = algo } } };
        }
    } else {
        for (out_names, outputs) |o, *no| {
            try drv.envSet(a, o, "");
            no.* = .{ .name = o, .output = .deferred };
        }
        const mi = blk: {
            ev.shared.drv_lock.lock(ev);
            defer ev.shared.drv_lock.unlock(ev);
            break :blk drv_mod.moduloInputs(a, drv, cache, loader, &d) catch |e| return drvFail(ev, &d, e, pos);
        };
        drv_mod.finalizeWithInputs(a, drv, mi, &d) catch |e| return drvFail(ev, &d, e, pos);
        modulo = mi;
    }

    // A text-addressed output is a `.drv`, so `builtins.outputOf` may read
    // this derivation back. Nix reads it from the store, which it has written
    // by then; iets writes nothing during an evaluation, so the ATerm of a
    // producer is kept.
    const produces_drv = b.ingestion_method == .text;
    var aterm: ?[]const u8 = null;
    const drv_path = blk: {
        if (produces_drv or ev.config.keep_aterm or ev.config.dump_dir != null) {
            const text = drv.unparseAlloc(ev.local.arena.allocator(), .{}, &d) catch |e| return drvFail(ev, &d, e, pos);
            aterm = text;
            break :blk drv.drvPathFor(a, text, &d) catch |e| return drvFail(ev, &d, e, pos);
        }
        break :blk drv.drvPath(a, &d) catch |e| return drvFail(ev, &d, e, pos);
    };
    const h = if (modulo) |mi|
        drv_mod.hashModuloWith(a, drv, false, mi, &d) catch |e| return drvFail(ev, &d, e, pos)
    else blk: {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        break :blk drv_mod.hashDerivationModulo(a, drv, false, cache, loader, &d) catch |e| return drvFail(ev, &d, e, pos);
    };
    {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        _ = try cache.put(&drv_path, h);
        ev.shared.drv.nr_derivations += 1;
    }

    // not held back like a warning: the value this derivation is part of
    // escapes into its cell whether or not the demand path takes the thunk
    // a helper was forcing, so a dump held back with that thunk would be
    // lost while the drvPath that names it is returned
    if (ev.config.dump_dir) |dir| try dumpDrv(ev, dir, drv_path.baseName(), aterm.?, pos);

    const drv_path_s = try pathString(ev, &drv_path);
    const refs = try ev.local.arena.allocSlice([]const u8, drv.input_srcs.len + drv.input_drvs.len);
    for (drv.input_srcs, refs[0..drv.input_srcs.len]) |*p, *r| r.* = try pathString(ev, p);
    for (drv.input_drvs, refs[drv.input_srcs.len..]) |*in, *r| r.* = try pathString(ev, &in.path);
    const names = try ev.local.arena.allocSlice([]const u8, outputs.len);
    for (outputs, names) |o, *n| n.* = try ev.local.arena.dupe(u8, o.name);
    const rendered = try ev.local.arena.allocSlice([]const u8, outputs.len);

    const entries = try ev.gpa.alloc(value.Attr, 1 + outputs.len);
    defer ev.gpa.free(entries);
    const dp_ctx = try ev.local.arena.dupe(Ctx, &.{.{ .kind = .drv_deep, .path = drv_path_s }});
    entries[0] = .{ .sym = ev.s.drvPath, .pos = .none, .cell = .init(try ev.mkStringStatic(drv_path_s, dp_ctx)) };
    for (outputs, names, entries[1..], rendered) |*o, n, *e, *r| {
        const v = try outputString(ev, drv.name, &drv_path, drv_path_s, n, &o.output, pos);
        r.* = v.as(value.String).bytes();
        e.* = .{ .sym = try ev.sym(n), .pos = .none, .cell = .init(v) };
    }
    const site = try drvSite(ev, attrs, pos);
    {
        ev.shared.drv_lock.lock(ev);
        defer ev.shared.drv_lock.unlock(ev);
        try putInfo(ev, drv_path.baseName(), .{ .outputs = names, .references = refs, .rendered = rendered, .aterm = aterm, .site = site });
    }
    return ev.mkAttrs(entries, pos);
}

/// Where a derivation was defined: the call itself when it is in a real
/// file, else the package's own `pname` (stdenv.mkDerivation computes `name`
/// but passes `pname` through, as nixpkgs' meta.position does), else the
/// first attribute still bound in a root tree (a name-only builder such as
/// runCommand loses the caller's `name` binding), else the `name`
/// attribute's value.
fn drvSite(ev: *Evaluator, attrs: *value.Attrs, pos: Pos) Error!Pos {
    if (!ev.config.keep_site) return .none;
    const provenance = @import("../provenance.zig");
    if (provenance.realPos(ev, pos)) |p| return p;
    if (attrs.get(try ev.sym("pname"))) |a| if (provenance.realPos(ev, a.pos)) |p| return p;
    const name_pos: Pos = if (attrs.get(ev.s.name)) |a| a.pos else .none;
    if (provenance.realPos(ev, lint.coerce.drvFallback(ev, attrs, pos, name_pos))) |p| return p;
    if (provenance.realPos(ev, name_pos)) |p| return p;
    return .none;
}

fn putInfo(ev: *Evaluator, base: []const u8, info: Info) Error!void {
    const gop = try ev.shared.drv.table.getOrPut(ev.gpa, base);
    if (!gop.found_existing) gop.key_ptr.* = try ev.local.arena.dupe(u8, base);
    gop.value_ptr.* = info;
}

/// Mirrors eval.cc:EvalState::mkOutputString: the output path, or a
/// downstream placeholder when it is not statically known, with `!out!drv`
/// context. `output` lives in the arena.
fn outputString(ev: *Evaluator, drv_name: []const u8, drv_path: *const StorePath, drv_path_s: []const u8, output: []const u8, out: *const drv_mod.Output, pos: Pos) Error!Value {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const text: []const u8 = switch (out.*) {
        .input_addressed => |p| try pathString(ev, &p),
        .fixed => |f| blk: {
            const p = path_mod.makeFixedOutputPathFor(f.method, f.hash, drv_name, output, &d) catch |e| return drvFail(ev, &d, e, pos);
            break :blk try pathString(ev, &p);
        },
        .deferred, .ca_floating => try ev.local.arena.dupe(u8, &(try downstreamPlaceholder(ev, drv_path, drv_name, output, pos))),
    };
    const c = try ev.local.arena.dupe(Ctx, &.{.{ .kind = .built, .path = drv_path_s, .output = output }});
    return ev.mkStringStatic(text, c);
}

const placeholder_len = 1 + 52;

/// Mirrors downstream-placeholder.cc:DownstreamPlaceholder::unknownCaOutput.
fn unknownCaOutput(ev: *Evaluator, drv_path: *const StorePath, drv_name: []const u8, output: []const u8, pos: Pos) Error!Hash {
    var buf: [path_mod.max_name_len + 64]u8 = undefined;
    const name = path_mod.outputPathName(&buf, drv_name, output) catch
        return ev.fail(.eval, pos, "name '{s}-{s}' must be no longer than {d} characters", .{ drv_name, output, path_mod.max_name_len });
    return unknownCaOutputHash(drv_path.hashPart(), name);
}

fn unknownCaOutputHash(hash_part: []const u8, output_path_name: []const u8) Hash {
    var h: hash_mod.Hasher = .init(.sha256);
    h.update("nix-upstream-output:");
    h.update(hash_part);
    h.update(":");
    h.update(output_path_name);
    return h.finish();
}

/// Mirrors downstream-placeholder.cc:DownstreamPlaceholder::unknownDerivation:
/// an output of a derivation that is itself the output of one.
fn unknownDerivation(parent: Hash, output: []const u8) Hash {
    var buf: [64]u8 = undefined;
    const c = hash_mod.compress(parent, 20);
    var h: hash_mod.Hasher = .init(.sha256);
    h.update("nix-computed-output:");
    h.update(c.print(&buf, .nix32, false));
    h.update(":");
    h.update(output);
    return h.finish();
}

/// Mirrors downstream-placeholder.cc:DownstreamPlaceholder::render.
fn renderPlaceholder(h: Hash) [placeholder_len]u8 {
    var out: [placeholder_len]u8 = undefined;
    out[0] = '/';
    _ = hash_mod.encodeNix32(out[1..], h.bytes());
    return out;
}

fn downstreamPlaceholder(ev: *Evaluator, drv_path: *const StorePath, drv_name: []const u8, output: []const u8, pos: Pos) Error![placeholder_len]u8 {
    return renderPlaceholder(try unknownCaOutput(ev, drv_path, drv_name, output, pos));
}

/// Mirrors eval.cc:mkSingleDerivedPathStringRaw of a `SingleDerivedPath::Built`:
/// `layers` are the output names above the `.drv` `root`, outermost first.
/// The path when the run can know it, the downstream placeholder otherwise.
fn renderBuilt(ev: *Evaluator, root: *const StorePath, layers: []const []const u8, output: []const u8, pos: Pos) Error![]const u8 {
    ev.shared.drv_lock.lock(ev);
    defer ev.shared.drv_lock.unlock(ev);
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const drv_name = Derivation.nameFromPath(root, &d) catch |e| return drvFail(ev, &d, e, pos);
    if (layers.len == 0) {
        // the derivation is a real `.drv`, so the output may have a path
        if (ev.shared.drv.table.get(root.baseName())) |info| if (info.rendered) |r| {
            for (info.outputs, r) |o, t| if (std.mem.eql(u8, o, output)) return t;
            var buf: [4096]u8 = undefined;
            return ev.fail(.eval, pos, "derivation '{s}' does not have output '{s}'", .{ root.print(&buf), output });
        };
        var tmp: std.heap.ArenaAllocator = .init(ev.gpa);
        defer tmp.deinit();
        const drv = loadDrv(ev, tmp.allocator(), root.*, &d) catch |e| return drvFail(ev, &d, e, pos);
        if (drv.output(output) == null) {
            var buf: [4096]u8 = undefined;
            return ev.fail(.eval, pos, "derivation '{s}' does not have output '{s}'", .{ root.print(&buf), output });
        }
        const p = drv.outputPath(output, &d) catch |e| return drvFail(ev, &d, e, pos);
        if (p) |sp| return pathString(ev, &sp);
        return ev.local.arena.dupe(u8, &(try downstreamPlaceholder(ev, root, drv_name, output, pos)));
    }
    // downstream-placeholder.cc:fromSingleDerivedPathBuilt, from the bottom up
    var h = try unknownCaOutput(ev, root, drv_name, try checkUtf8(ev, layers[layers.len - 1], pos), pos);
    var i = layers.len - 1;
    while (i > 0) {
        i -= 1;
        h = unknownDerivation(h, try checkUtf8(ev, layers[i], pos));
    }
    return ev.local.arena.dupe(u8, &renderPlaceholder(unknownDerivation(h, output)));
}

/// primops.cc:prim_outputOf. The first argument is a string whose one context
/// element names a derivation; the second an output of it. The result names
/// that output, and carries it as context, so a derivation that uses the
/// string depends on it.
fn outputOf(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try ev.forceString(args[0], pos, "while evaluating the first argument to builtins.outputOf");
    const name = try checkUtf8(ev, try ev.forceStringNoCtx(args[1], pos, "while evaluating the second argument to builtins.outputOf"), pos);
    // eval.cc:coerceToSingleDerivedPathUnchecked. The impure marks are iets's
    // own and no part of what Nix counts.
    var n: usize = 0;
    var elem: Ctx = undefined;
    for (s.context()) |c| if (c.isStore()) {
        n += 1;
        elem = c;
    };
    const text = s.bytes();
    if (n != 1)
        return ev.fail(.eval, pos, "string '{s}' has {d} entries in its context. It should only have exactly one entry", .{ text, n });
    var tmp: std.heap.ArenaAllocator = .init(ev.gpa);
    defer tmp.deinit();
    // the derivation the result's output comes from, as a `built` context path
    var drv: []const u8 = undefined;
    var expected: []const u8 = undefined;
    switch (elem.kind) {
        .opaque_path => {
            drv = elem.path;
            expected = elem.path;
        },
        .drv_deep => return ev.fail(.eval, pos, "string '{s}' has a context which refers to a complete source and binary closure. This is not supported at this time", .{text}),
        .built => {
            const sb = try splitBuilt(tmp.allocator(), elem.path);
            const root = try parseStorePath(ev, sb.root, pos);
            const out = try checkUtf8(ev, elem.output, pos);
            expected = try renderBuilt(ev, &root, sb.layers, out, pos);
            drv = try std.mem.concat(ev.local.arena.allocator(), u8, &.{ elem.output, "!", elem.path });
        },
        .impure_path, .impure_meta => unreachable,
    }
    if (!std.mem.eql(u8, text, expected))
        return ev.fail(.eval, pos, "string '{s}' has context with a derivation output, but the string is not the right placeholder for it. It should be '{s}'", .{ text, expected });
    const sb = try splitBuilt(tmp.allocator(), drv);
    const root = try parseStorePath(ev, sb.root, pos);
    const rendered = try renderBuilt(ev, &root, sb.layers, name, pos);
    const c = try ev.local.arena.dupe(Ctx, &.{.{ .kind = .built, .path = drv, .output = try ev.local.arena.dupe(u8, name) }});
    return ev.mkStringStatic(rendered, c);
}

/// Output names and `.drv` references of `p`: from this evaluation's table,
/// else parsed from the store (and then remembered).
fn drvInfo(ev: *Evaluator, p: *const StorePath, pos: Pos) Error!Info {
    ev.shared.drv_lock.lock(ev);
    defer ev.shared.drv_lock.unlock(ev);
    if (ev.shared.drv.table.get(p.baseName())) |i| return i;
    var tmp: std.heap.ArenaAllocator = .init(ev.gpa);
    defer tmp.deinit();
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const drv = drv_mod.loadDerivationFromStore(ev.io, tmp.allocator(), p.*, &d) catch |e| return drvFail(ev, &d, e, pos);
    const refs = try ev.local.arena.allocSlice([]const u8, drv.input_srcs.len + drv.input_drvs.len);
    for (drv.input_srcs, refs[0..drv.input_srcs.len]) |*sp, *r| r.* = try pathString(ev, sp);
    for (drv.input_drvs, refs[drv.input_srcs.len..]) |*in, *r| r.* = try pathString(ev, &in.path);
    const names = try ev.local.arena.allocSlice([]const u8, drv.outputs.len);
    for (drv.outputs, names) |o, *nm| nm.* = try ev.local.arena.dupe(u8, o.name);
    const info: Info = .{ .outputs = names, .references = refs };
    try putInfo(ev, p.baseName(), info);
    return info;
}

const ClosureEntry = struct { path: []const u8, outputs: ?[]const []const u8 };

/// Mirrors `computeFSClosure` on a `.drv` path as used for `drv_deep` context:
/// the drv, its inputs, and their closures. A source this evaluation added
/// with `builtins.toFile` carries its own references; a store path that was
/// already on disk is a leaf, because evaluation does not ask the daemon.
fn drvClosure(ev: *Evaluator, a: Allocator, start: []const u8, pos: Pos) Error![]const ClosureEntry {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var todo: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(ClosureEntry) = .empty;
    try todo.append(a, start);
    while (todo.pop()) |p| {
        if ((try seen.getOrPut(a, p)).found_existing) continue;
        const sp = try parseStorePath(ev, p, pos);
        if (sp.isDerivation()) {
            const info = try drvInfo(ev, &sp, pos);
            try todo.appendSlice(a, info.references);
            try out.append(a, .{ .path = p, .outputs = info.outputs });
        } else {
            // a text this evaluation added carries its own references
            if (@import("store_hooks.zig").origin(ev, &sp)) |o| if (o.src == .mem) for (o.refs) |*r|
                try todo.append(a, try std.fmt.allocPrint(a, "{f}", .{r}));
            try out.append(a, .{ .path = p, .outputs = null });
        }
    }
    return out.items;
}

/// Mirrors primops.cc:prim_placeholder.
fn placeholder(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const s = try checkUtf8(ev, try ev.forceStringNoCtx(args[0], pos, "while evaluating the first argument passed to builtins.placeholder"), pos);
    const ph = path_mod.hashPlaceholder(s);
    return ev.mkString(&ph);
}

/// Mirrors primops.cc:derivationToValue for `import /nix/store/...drv`:
/// null when `path` is not an existing `.drv` store path.
pub fn importDerivation(ev: *Evaluator, path: []const u8, pos: Pos) Error!?Value {
    if (!std.mem.endsWith(u8, path, path_mod.drv_extension)) return null;
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const sp = StorePath.parse(path, &d) catch return null;
    if (try @import("store_hooks.zig").stat(ev, path, true) != .regular) return null;
    var tmp: std.heap.ArenaAllocator = .init(ev.gpa);
    defer tmp.deinit();
    const drv = loadDrv(ev, tmp.allocator(), sp, &d) catch |e| return drvFail(ev, &d, e, pos);
    const drv_name = try ev.local.arena.dupe(u8, Derivation.nameFromPath(&sp, &d) catch |e| return drvFail(ev, &d, e, pos));
    const path_s = try ev.local.arena.dupe(u8, path);
    const outputs_sym = (try syms(ev)).outputs;
    const entries = try ev.gpa.alloc(value.Attr, 3 + drv.outputs.len);
    defer ev.gpa.free(entries);
    const dp_ctx = try ev.local.arena.dupe(Ctx, &.{.{ .kind = .drv_deep, .path = path_s }});
    entries[0] = .{ .sym = ev.s.drvPath, .pos = .none, .cell = .init(try ev.mkStringStatic(path_s, dp_ctx)) };
    entries[1] = .{ .sym = ev.s.name, .pos = .none, .cell = .init(try ev.mkString(drv.envGet("name") orelse "")) };
    const names = try ev.gpa.alloc(Value, drv.outputs.len);
    defer ev.gpa.free(names);
    for (drv.outputs, entries[3..], names) |*o, *e, *nv| {
        const n = try ev.local.arena.dupe(u8, o.name);
        e.* = .{ .sym = try ev.sym(n), .pos = .none, .cell = .init(try outputString(ev, drv_name, &sp, path_s, n, &o.output, pos)) };
        nv.* = try ev.mkStringStatic(n, &.{});
    }
    entries[2] = .{ .sym = outputs_sym, .pos = .none, .cell = .init(try ev.mkList(names)) };
    const attrs = try ev.mkAttrs(entries, pos);
    ev.shared.drv_lock.lock(ev);
    const f = ev.shared.drv.imported_drv_fn orelse blk: {
        errdefer ev.shared.drv_lock.unlock(ev);
        const code = try import_.compileSource(ev, "«imported-drv-to-derivation»", imported_drv_to_derivation, "/", null);
        const f = try ev.eval(ev.root_env, code);
        ev.shared.drv.imported_drv_fn = f;
        break :blk f;
    };
    ev.shared.drv_lock.unlock(ev);
    return try ev.call1(f, attrs, pos);
}

/// Nix 2.34.8 src/libexpr/imported-drv-to-derivation.nix.
const imported_drv_to_derivation =
    \\attrs@{ drvPath, outputs, name, ... }:
    \\let
    \\  commonAttrs = (builtins.listToAttrs outputsList) // {
    \\    all = map (x: x.value) outputsList;
    \\    inherit drvPath name;
    \\    type = "derivation";
    \\  };
    \\  outputToAttrListElement = outputName: {
    \\    name = outputName;
    \\    value = commonAttrs // {
    \\      outPath = builtins.getAttr outputName attrs;
    \\      inherit outputName;
    \\    };
    \\  };
    \\  outputsList = map outputToAttrListElement outputs;
    \\in
    \\(builtins.head outputsList).value
    \\
;

const testing = std.testing;

// The reference values come from nix 2.35pre, `--extra-experimental-features
// 'ca-derivations dynamic-derivations'`.
test "a dynamic output renders the placeholder nix renders" {
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const p = try StorePath.parse("/nix/store/y86qixskwxs9z8i9gbd9x06h3q0hy1ji-p.drv.drv", &d);
    const h = unknownDerivation(unknownCaOutputHash(p.hashPart(), "p.drv"), "out");
    try testing.expectEqualStrings("/1k5662fdf252qa1rsrq0s5xc0w9a9wb1qsgzfk2i9zhx4as0qf76", &renderPlaceholder(h));

    const q = try StorePath.parse("/nix/store/czdvshq1r2b3acsxv0r6jmrr3jg302mq-q.drv.drv.drv", &d);
    var h2 = unknownCaOutputHash(q.hashPart(), "q.drv.drv");
    for (0..2) |_| h2 = unknownDerivation(h2, "out");
    try testing.expectEqualStrings("/16v25j0s9i1rfcgz7lcr8hlsh14m83b35f0c63lkgcpwj9nj4c9s", &renderPlaceholder(h2));
}

test "splitBuilt takes the layers apart" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const sb = try splitBuilt(arena.allocator(), "a!b!/nix/store/x.drv");
    try testing.expectEqualStrings("/nix/store/x.drv", sb.root);
    try testing.expectEqual(2, sb.layers.len);
    try testing.expectEqualStrings("a", sb.layers[0]);
    const sb2 = try splitBuilt(arena.allocator(), "/nix/store/x.drv");
    try testing.expectEqual(0, sb2.layers.len);
}
