//! A locked reference's tree: read from `/nix/store` when it is there, else
//! from the user-level input store (`treestore.zig`), else substituted by a
//! daemon if one is reachable, else downloaded into the input store by iets
//! itself (`github`, `gitlab`, `sourcehut`, `tarball`), else fetched by
//! running `nix` once (`git`, `hg`). Only that last step needs a daemon.
//!
//! The `narHash` is known before the fetch, so the tree names itself and the
//! input store refuses anything that does not hash to it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Pos = @import("../syntax/pos.zig").Pos;
const Diag = @import("../diag.zig").Diag;
const hash_mod = @import("../store/hash.zig");
const Hash = hash_mod.Hash;
const store_path = @import("../store/path.zig");
const StorePath = store_path.StorePath;
const IngestionMethod = store_path.IngestionMethod;
const nar = @import("../store/nar.zig");
const hooks = @import("../builtins/store_hooks.zig");
const treestore = @import("../treestore.zig");
const spool = @import("../fetch/spool.zig");
const http = @import("../fetch/http.zig");
const config = @import("../config.zig");
const log_mod = @import("../log.zig");
const nixbin = @import("../nixbin.zig");
const env_mod = @import("../env.zig");
const worker = @import("../remote/worker.zig");
const event = @import("../remote/event.zig");
const PathSet = @import("../remote/plan.zig").PathSet;
const source = @import("../source.zig");
const Attrs = source.Attrs;
const AttrVal = source.AttrVal;
const strAttr = source.strAttr;
const Tree = source.Tree;
const scm = @import("scm.zig");
const trace = @import("../trace.zig");
const proc = @import("proc.zig");

/// A locked input's tree, named by the lock's `narHash` and readable at that
/// store path when this returns. The `fetchTree` builtin and `nix flake
/// prefetch-inputs` are the two callers, and they must agree on the name.
pub fn locked(ev: *Evaluator, attrs_in: *const Attrs, pos: Pos) Error!Tree {
    const a = ev.local.arena.allocator();
    const nar_hash = strAttr(attrs_in, "narHash") orelse {
        return ev.failHint(.unsupported, pos, "iets needs the 'narHash' to know the store path: pass it to fetchTree, or run 'nix flake update' to write it into flake.lock", "cannot fetch unlocked input '{s}' (no narHash); run nix flake lock", .{try source.toUrl(a, attrs_in)});
    };
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const hash = source.parseNarHash(nar_hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    var attrs = try attrs_in.clone(a);
    try attrs.put(a, "narHash", .{ .str = try hash.alloc(a, .sri, true) });
    const path = treestore.storePath("source", hash, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    try ensureReadable(ev, &path, hash, &attrs, pos);
    return .{ .path = path, .attrs = attrs };
}

/// The lock file's name for a locked input, else its attrs as a URL.
fn inputName(ev: *Evaluator, attrs: *const Attrs) Error![]const u8 {
    if (strAttr(attrs, "narHash")) |h| if (inputNameOf(ev, h)) |n| return n;
    return source.toUrl(ev.local.arena.allocator(), attrs);
}

/// The lock's node name for the input whose `narHash` is `h`.
pub fn inputNameOf(ev: *Evaluator, h: []const u8) ?[]const u8 {
    ev.shared.input_names_lock.lockUncancelable(ev.io);
    defer ev.shared.input_names_lock.unlock(ev.io);
    return ev.shared.input_names.get(h);
}

/// Names the input whose `narHash` is `h` (a lock node name), unless named.
pub fn nameInput(ev: *Evaluator, h: []const u8, name: []const u8) Error!void {
    const a = ev.local.arena.allocator();
    ev.shared.input_names_lock.lockUncancelable(ev.io);
    defer ev.shared.input_names_lock.unlock(ev.io);
    const gop = try ev.shared.input_names.getOrPut(ev.gpa, h);
    if (gop.found_existing) return;
    gop.key_ptr.* = try a.dupe(u8, h);
    gop.value_ptr.* = try a.dupe(u8, name);
}

/// A Nix `"..."` literal holding `s`.
pub fn nixStringLiteral(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(a, s.len + 2);
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '$' => try out.appendSlice(a, "\\$"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
    return out.toOwnedSlice(a);
}

/// The evaluation's connections to the eval store, opened on the first
/// input missing from `/nix/store` and kept for the rest of the run. The
/// eval store is nix.conf's `store`, never the `builder` setting: a remote
/// builder has no say in what `import` reads. A `grpc://` store is not a
/// worker-protocol daemon, so there is nothing to open and nothing to
/// substitute with. One table for every worker, as the protocol is one request at a time.
pub const Daemon = struct {
    lock: Io.Mutex = .init,
    /// The connection that answers what is valid, for a daemon on this
    /// machine only: a remote store's database says nothing about the
    /// files here.
    valid_conn: ?*worker.Connection = null,
    valid_tried: bool = false,
    valid: PathSet = .empty,
    /// The connection that substitutes.
    sub_conn: ?*worker.Connection = null,
    sub_tried: bool = false,
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(dm: *Daemon, gpa: Allocator) void {
        if (dm.valid_conn) |c| c.close();
        if (dm.sub_conn) |c| c.close();
        dm.valid.deinit(gpa);
        if (dm.arena) |*x| x.deinit();
    }

    fn alloc(dm: *Daemon, gpa: Allocator) Allocator {
        if (dm.arena == null) dm.arena = .init(gpa);
        return dm.arena.?.allocator();
    }
};

/// The eval store's transport; null without a session (a test), whose
/// evaluation asks no daemon.
fn storeTransport(ev: *Evaluator, a: Allocator) ?worker.Transport {
    const s = ev.config.session orelse return null;
    const c = s.nix_conf orelse return null;
    return worker.Transport.parse(a, c.store(), s.env.map);
}

fn openConn(ev: *Evaluator, t: *const worker.Transport) ?*worker.Connection {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const env = if (ev.config.session) |s| s.env.map else null;
    return worker.Connection.open(ev.gpa, ev.io, t, env, .none, .ignore, &d) catch null;
}

/// `null` when there is no local daemon to ask. The first query also asks
/// about the lock's other inputs on disk, which the evaluation is likely to
/// ask about next.
fn registered(ev: *Evaluator, sp: *const StorePath) ?bool {
    const dm = &ev.shared.daemon;
    dm.lock.lockUncancelable(ev.io);
    defer dm.lock.unlock(ev.io);
    if (dm.valid.contains(sp.*)) return true;
    const a = dm.alloc(ev.gpa);
    var ask: std.ArrayList(StorePath) = .empty;
    defer ask.deinit(ev.gpa);
    ask.append(ev.gpa, sp.*) catch return null;
    if (!dm.valid_tried) {
        dm.valid_tried = true;
        if (storeTransport(ev, a)) |t| if (t == .unix) {
            dm.valid_conn = openConn(ev, &t);
        };
        if (dm.valid_conn != null) moreInputs(ev, &ask) catch {};
    }
    const c = dm.valid_conn orelse return null;
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    var scratch: std.heap.ArenaAllocator = .init(ev.gpa);
    defer scratch.deinit();
    const got = c.queryValid(scratch.allocator(), ask.items, .ignore, &d) catch {
        c.close();
        dm.valid_conn = null;
        return null;
    };
    for (got) |p| dm.valid.put(ev.gpa, p, {}) catch {};
    return dm.valid.contains(sp.*);
}

/// The store paths of the lock's inputs that are on disk.
fn moreInputs(ev: *Evaluator, out: *std.ArrayList(StorePath)) !void {
    ev.shared.input_names_lock.lockUncancelable(ev.io);
    defer ev.shared.input_names_lock.unlock(ev.io);
    var it = ev.shared.input_names.keyIterator();
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    while (it.next()) |h| {
        const hash = source.parseNarHash(h.*, &d) catch continue;
        const sp = treestore.storePath("source", hash, &d) catch continue;
        var buf: [512]u8 = undefined;
        const full = sp.print(&buf);
        if (trace.statKind(full, true) == .missing) continue;
        try out.append(ev.gpa, sp);
    }
}

/// store-api.cc:isValidPath for a store path whose content `method` and
/// `hash` name. A file or directory there may be what an interrupted build
/// or copy left, which the store never registered. The local daemon
/// answers; without one the bytes must hash to `hash`. Only a valid path's
/// kind is recorded: it cannot change while the path stays valid.
pub fn validInStore(ev: *Evaluator, sp: *const StorePath, method: IngestionMethod, hash: Hash) bool {
    var buf: [512]u8 = undefined;
    const full = sp.print(&buf);
    const Ask = struct {
        ev: *Evaluator,
        sp: *const StorePath,
        pub fn call(x: @This()) ?bool {
            return registered(x.ev, x.sp);
        }
    };
    const kind = validKind(ev.gpa, ev.io, full, method, hash, Ask{ .ev = ev, .sp = sp }) orelse return false;
    ev.trace().stat(full, true, kind);
    return true;
}

/// The kind of `path` when it holds a valid store path. `ask.call()` is the
/// store's answer, null when there is no store to ask.
fn validKind(gpa: Allocator, io: Io, path: []const u8, method: IngestionMethod, hash: Hash, ask: anytype) ?hooks.Kind {
    const kind = trace.statKind(path, true);
    if (kind == .missing) return null;
    const valid = ask.call() orelse hashesTo(gpa, io, path, method, hash);
    return if (valid) kind else null;
}

fn hashesTo(gpa: Allocator, io: Io, path: []const u8, method: IngestionMethod, hash: Hash) bool {
    var d: Diag = .init(gpa);
    defer d.deinit();
    const got = switch (method) {
        .recursive => (nar.narHashFiltered(gpa, io, Io.Dir.cwd(), path, hash.algo, nar.keep_all, &d) catch return false).hash,
        .flat, .text => blk: {
            const st = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return false;
            if (st.kind != .file) return false;
            break :blk nar.flatHash(io, Io.Dir.cwd(), path, hash.algo, &d) catch return false;
        },
    };
    return got.eql(hash);
}

/// fetchers.cc:getAccessorUnchecked: a locked input carries `__final`, so
/// Nix substitutes its store path before it runs any fetcher. An expression
/// cannot mark an input final, so iets substitutes the tree itself before
/// it fetches. One `QueryValidPaths` with the substitute flag does it.
fn substitute(ev: *Evaluator, sp: *const StorePath, full: []const u8) bool {
    const dm = &ev.shared.daemon;
    dm.lock.lockUncancelable(ev.io);
    defer dm.lock.unlock(ev.io);
    const a = dm.alloc(ev.gpa);
    if (!dm.sub_tried) {
        dm.sub_tried = true;
        // a missing daemon is not an error: the input store holds the
        // fetched inputs and evaluation writes no store
        if (storeTransport(ev, a)) |t| if (t != .grpc) {
            dm.sub_conn = openConn(ev, &t);
        };
    }
    const c = dm.sub_conn orelse return false;
    // the daemon's own lines, such as a substituter it retries
    const Said = struct {
        ev: *Evaluator,
        pub fn onEvent(s: *@This(), e: event.Event) void {
            if (e == .log) s.ev.log("{f}", .{@import("../syntax/text.zig").lossy(e.log.line)});
        }
    };
    var said: Said = .{ .ev = ev };
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const got = c.substitutePaths(a, sp[0..1], .of(Said, &said), &d) catch {
        ev.log("iets: cannot substitute '{s}': {s}", .{ full, d.message() });
        return false;
    };
    for (got) |*p| if (p.eql(sp)) return true;
    return false;
}

/// A remote input's tree must be readable at its store path so `import`
/// reads exactly what Nix reads. `/nix/store` is used when it has the tree,
/// then the user-level input store; a tarball-shaped input in neither is
/// downloaded into that, and reads come out of its packs. A reachable
/// daemon is asked to substitute first, since a local copy beats a
/// download. A `git` or `hg` input still goes through Nix's `fetchTree`,
/// which writes `/nix/store`. Never called for the root tree or a `path`
/// input.
pub fn ensureReadable(ev: *Evaluator, sp: *const StorePath, nar_hash: Hash, attrs: *const Attrs, pos: Pos) Error!void {
    var buf: [512]u8 = undefined;
    const full = try ev.local.arena.allocator().dupe(u8, sp.print(&buf));
    if (validInStore(ev, sp, .recursive, nar_hash)) return adoptStore(ev, sp);
    if (ev.config.inputs) |s| if (s.get(sp.baseName())) |entry| return adopt(ev, sp, entry);
    const name = try inputName(ev, attrs);
    ev.log("iets: input '{s}' is not in the store ({s}), fetching it", .{ name, full });
    if (substitute(ev, sp, full)) {
        ev.trace().stat(full, true, .directory);
        return adoptStore(ev, sp);
    }
    if (isTarballType(attrs)) {
        const entry = try fetchTarball(ev, sp, nar_hash, attrs, name, pos);
        return adopt(ev, sp, entry);
    }
    try fetchWithNix(ev, full, name, attrs, pos);
    if (ev.trace().statNow(full, true) == .missing)
        return ev.fail(.io, pos, "iets: input '{s}' is not in the store ({s})", .{ name, full });
    return adoptStore(ev, sp);
}

/// Points every read of `sp` at the input store entry, and records the
/// entry in the read set (`treestore.record`).
fn adopt(ev: *Evaluator, sp: *const StorePath, entry: *treestore.StoredTree) Error!void {
    try hooks.addStoredTree(ev, sp, entry);
    treestore.record(ev.trace(), entry);
}

/// `adopt` for a flat file, which is addressed by the hash of its bytes and
/// not by its NAR hash.
fn adoptFile(ev: *Evaluator, sp: *const StorePath, entry: *treestore.StoredTree) Error!void {
    try hooks.addStoredTree(ev, sp, entry);
    treestore.record(ev.trace(), entry);
}

/// A path that is simply in `/nix/store`: pure evaluation may read it, and
/// reads go where it lies.
pub fn adoptStore(ev: *Evaluator, sp: *const StorePath) Error!void {
    try hooks.addOnDisk(ev, sp);
}

/// The context of a download: the run's limits, and its stderr for retries.
fn httpContext(ev: *Evaluator) http.Context {
    return .{ .gpa = ev.gpa, .io = ev.io, .limits = ev.config.fetch_limits, .offline = ev.config.offline, .log = if (ev.config.session) |x| &x.log else null };
}

const Waiting = struct {
    ev: *Evaluator,
    what: []const u8,

    pub fn call(w: @This()) void {
        w.ev.log("{s}", .{w.what});
    }
};

/// The types whose fetch is "download one archive and unpack it"
/// (github.cc:GitArchiveInputScheme, tarball.cc:TarballInputScheme). `git`
/// and `hg` are not here: they need a repository, so they still go through
/// nix. `file` is not either: its store path is the flat hash of the bytes
/// under the input's name, which the lock's `narHash` does not give, so iets
/// cannot say where the file belongs before it has it.
pub fn isTarballType(attrs: *const Attrs) bool {
    const t = strAttr(attrs, "type") orelse "";
    for ([_][]const u8{ "github", "gitlab", "sourcehut", "tarball" }) |x| if (std.mem.eql(u8, t, x)) return true;
    return false;
}

/// github.cc:getAccessToken: the longest `access-tokens` key that is a
/// prefix of `host/owner/repo` and ends on a path segment, else the entry
/// for the host.
pub fn accessToken(cfg: ?*const config.Config, host: []const u8, host_and_path: []const u8) ?[]const u8 {
    const c = cfg orelse return null;
    var best: ?[]const u8 = null;
    var best_len: usize = 0;
    var for_host: ?[]const u8 = null;
    var it = c.list("access-tokens");
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        const value = entry[eq + 1 ..];
        if (std.mem.eql(u8, key, host)) for_host = value;
        if (std.mem.startsWith(u8, host_and_path, key) and
            (host_and_path.len == key.len or host_and_path[key.len] == '/') and
            (best == null or key.len > best_len))
        {
            best = value;
            best_len = key.len;
        }
    }
    return best orelse for_host;
}

/// The `Authorization`-style header each forge wants for its token
/// (github.cc:accessHeaderFromToken, one override per scheme).
fn accessHeader(a: Allocator, ty: []const u8, token: []const u8) Allocator.Error!http.Header {
    if (std.mem.eql(u8, ty, "sourcehut")) return .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) };
    if (std.mem.eql(u8, ty, "gitlab")) {
        const colon = std.mem.indexOfScalar(u8, token, ':') orelse return .{ .name = token, .value = token };
        const n = token[0..colon];
        const v = token[colon + 1 ..];
        if (std.mem.eql(u8, n, "OAuth2")) return .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{v}) };
        if (std.mem.eql(u8, n, "PAT")) return .{ .name = "Private-token", .value = v };
        return .{ .name = n, .value = v };
    }
    return .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "token {s}", .{token}) };
}

pub const Download = struct { url: []const u8, headers: []const http.Header };

/// github.cc:getDownloadUrl and tarball.cc: the URL and headers Nix
/// downloads a locked archive input from. The `rev` is the 40 hex digits
/// the lock holds. The reason goes to `d` when the lock lacks a part.
pub fn tarballUrl(a: Allocator, cfg: ?*const config.Config, attrs: *const Attrs, d: *Diag) error{ Bad, OutOfMemory }!Download {
    const ty = strAttr(attrs, "type") orelse "";
    if (std.mem.eql(u8, ty, "tarball")) {
        const url = strAttr(attrs, "url") orelse return d.fail(error.Bad, "the lock has no 'url'", .{});
        return .{ .url = url, .headers = &.{} };
    }
    const owner = strAttr(attrs, "owner") orelse return d.fail(error.Bad, "the lock has no 'owner'", .{});
    const repo = strAttr(attrs, "repo") orelse return d.fail(error.Bad, "the lock has no 'repo'", .{});
    const rev = strAttr(attrs, "rev") orelse return d.fail(error.Bad, "the lock has no 'rev'", .{});
    const gitlab = std.mem.eql(u8, ty, "gitlab");
    const sourcehut = std.mem.eql(u8, ty, "sourcehut");
    const default_host = if (gitlab) "gitlab.com" else if (sourcehut) "git.sr.ht" else "github.com";
    const host = strAttr(attrs, "host") orelse default_host;
    const hp = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ host, owner, repo });
    var headers: []const http.Header = &.{};
    if (accessToken(cfg, host, hp)) |t| {
        const h = try a.alloc(http.Header, 1);
        h[0] = try accessHeader(a, ty, t);
        headers = h;
    }
    const url = if (gitlab)
        try std.fmt.allocPrint(a, "https://{s}/api/v4/projects/{s}%2F{s}/repository/archive.tar.gz?sha={s}", .{ host, owner, repo, rev })
    else if (sourcehut)
        try std.fmt.allocPrint(a, "https://{s}/{s}/{s}/archive/{s}.tar.gz", .{ host, owner, repo, rev })
        // With a token the API endpoint; without one the public archive,
        // which has the looser rate limit.
    else if (!std.mem.eql(u8, host, "github.com"))
        try std.fmt.allocPrint(a, "https://{s}/api/v3/repos/{s}/{s}/tarball/{s}", .{ host, owner, repo, rev })
    else if (headers.len == 0)
        try std.fmt.allocPrint(a, "https://{s}/{s}/{s}/archive/{s}.tar.gz", .{ host, owner, repo, rev })
    else
        try std.fmt.allocPrint(a, "https://api.{s}/repos/{s}/{s}/tarball/{s}", .{ host, owner, repo, rev });
    return .{ .url = url, .headers = headers };
}

fn nixConf(ev: *Evaluator) ?*const config.Config {
    const s = ev.config.session orelse return null;
    return if (s.nix_conf) |*c| c else null;
}

/// Downloads the input's archive into the input store, indexes it like Nix
/// unpacks it, checks the NAR hash against the lock and keeps the spool.
/// The archive is streamed: the only copy is the decompressed tar, which the
/// NAR is written out of once to hash it. A tree whose hash is not the
/// lock's is thrown away, so a wrong tree is never named, never read and
/// never uploaded. Nothing is registered anywhere.
fn fetchTarball(ev: *Evaluator, sp: *const StorePath, expected: Hash, attrs: *const Attrs, name: []const u8, pos: Pos) Error!*treestore.StoredTree {
    const a = ev.local.arena.allocator();
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const dl = tarballUrl(a, nixConf(ev), attrs, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Bad => return ev.fail(.eval, pos, "iets: cannot fetch input '{s}': {s}", .{ name, d.message() }),
    };
    const s = ev.config.inputs orelse return ev.fail(.eval, pos, "iets: cannot fetch input '{s}': no cache directory to hold it", .{name});
    const lk = s.fetchLock(sp.baseName(), Waiting{ .ev = ev, .what = try std.fmt.allocPrint(a, "iets: waiting for another process to fetch input '{s}'", .{name}) });
    defer if (lk) |l| s.unlock(l);
    if (s.reopen(sp.baseName())) |entry| return entry;
    var staged = s.stage(sp.baseName()) orelse return ev.fail(.eval, pos, "iets: cannot fetch input '{s}': no cache directory to hold it", .{name});
    const file = spool.spoolFile(ev.io, staged.dir) catch |e| {
        staged.deinit();
        return ev.fail(.eval, pos, "iets: cannot fetch input '{s}': {f}", .{ name, http.ioText(e) });
    };
    var wbuf: [64 << 10]u8 = undefined;
    var fw = file.writer(ev.io, &wbuf);
    _ = http.getDecompressed(httpContext(ev), dl.url, dl.headers, &fw.interface, &d) catch |e| {
        file.close(ev.io);
        staged.deinit();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.FetchFailed => ev.fail(.eval, pos, "iets: cannot fetch input '{s}': {s}", .{ name, d.message() }),
        };
    };
    fw.interface.flush() catch {
        file.close(ev.io);
        staged.deinit();
        return ev.fail(.eval, pos, "iets: cannot fetch input '{s}': cannot write the download", .{name});
    };
    var tree = spool.Tree.index(ev.gpa, ev.io, file, ev.config.fetch_limits.max_size, &d) catch |e| {
        staged.deinit();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => ev.fail(.eval, pos, "iets: cannot unpack input '{s}': {s}", .{ name, d.message() }),
        };
    };
    // the store verifies the tree against the lock's hash and names it by
    // what it hashes to, so a wrong tree is never named, read or uploaded
    var why: treestore.Rejected = undefined;
    return s.put(sp.name(), .recursive, expected, &staged, &tree, &why, &d) catch switch (why) {
        .mismatch => |got| {
            var eb: [Hash.max_string_len]u8 = undefined;
            var gb: [Hash.max_string_len]u8 = undefined;
            return hashMismatch(ev, pos, got, null, "iets: NAR hash mismatch in input '{s}' ({s}): expected '{s}' but the tree iets fetched hashes to '{s}'", .{ name, try http.shown(a, dl.url), expected.print(&eb, .sri, true), got.print(&gb, .sri, true) });
        },
        .io => ev.fail(.io, pos, "iets: cannot hash the tree of input '{s}': {s}", .{ name, d.message() }),
        .unstorable => ev.fail(.eval, pos, "iets: cannot keep the fetched input '{s}' in the input store", .{name}),
    };
}

/// A hash mismatch error whose fix names the hash the tree has, and
/// where the wrong one is written when that is known.
pub fn hashMismatch(ev: *Evaluator, pos: Pos, got: Hash, at: ?[]const u8, comptime fmt: []const u8, args: anytype) Error {
    var gb: [Hash.max_string_len]u8 = undefined;
    const g = got.print(&gb, .sri, true);
    const hint = if (at) |p|
        try std.fmt.allocPrint(ev.gpa, "set narHash at {s} to '{s}'", .{ p, g })
    else
        try std.fmt.allocPrint(ev.gpa, "set narHash to '{s}'", .{g});
    defer ev.gpa.free(hint);
    return ev.failHint(.hash_mismatch, pos, hint, fmt, args);
}

/// A directory being built from a revision's entries.
const Building = struct {
    entries: std.StringArrayHashMapUnmanaged(Built) = .empty,

    const Built = union(enum) { dir: *Building, leaf: spool.Node };

    fn dir(b: *Building, a: Allocator, parts: []const []const u8) Allocator.Error!*Building {
        var at = b;
        for (parts) |p| {
            const gop = try at.entries.getOrPut(a, p);
            if (!gop.found_existing or gop.value_ptr.* != .dir) {
                const nb = try a.create(Building);
                nb.* = .{};
                gop.value_ptr.* = .{ .dir = nb };
            }
            at = gop.value_ptr.dir;
        }
        return at;
    }

    fn node(b: *const Building, a: Allocator) Allocator.Error!spool.Node {
        const out = try a.alloc(spool.Entry, b.entries.count());
        for (b.entries.keys(), b.entries.values(), out) |k, v, *o| o.* = .{ .name = k, .node = switch (v) {
            .dir => |d| try d.node(a),
            .leaf => |n| n,
        } };
        std.mem.sortUnstable(spool.Entry, out, {}, struct {
            fn lt(_: void, x: spool.Entry, y: spool.Entry) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        return .{ .dir = out };
    }
};

pub const Stored = struct { path: StorePath, hash: Hash };

/// The tree of a revision as the store path `name` gives it, readable there
/// when this returns: `/nix/store` when it holds the tree, else the input
/// store, which takes it in when it does not have it. The tree is hashed
/// first, since nothing names it before.
pub fn storeCommit(ev: *Evaluator, name: []const u8, commit: scm.Commit, pos: Pos) Error!Stored {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const file = spool.scratch(ev.io, "commit", &d) catch return ev.fail(.io, pos, "{s}", .{d.message()});
    var arena: std.heap.ArenaAllocator = .init(ev.gpa);
    const a = arena.allocator();
    var owned = true;
    defer if (owned) {
        arena.deinit();
        file.close(ev.io);
    };
    var wbuf: [64 << 10]u8 = undefined;
    var fw = file.writer(ev.io, &wbuf);
    var offset: u64 = 0;
    var root: Building = .{};
    for (commit.entries) |e| {
        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, e.path, '/');
        while (it.next()) |p| try parts.append(a, try a.dupe(u8, p));
        const leaf: spool.Node = switch (e.entry) {
            .empty => {
                _ = try root.dir(a, parts.items);
                continue;
            },
            .symlink => |t| .{ .symlink = try a.dupe(u8, t) },
            .file => |f| blk: {
                fw.interface.writeAll(f.bytes) catch return ev.fail(.io, pos, "cannot write the spool of a Git tree", .{});
                const size: u64 = f.bytes.len;
                const at: spool.Blob = .{ .spool = .{ .offset = offset, .size = size, .sparse = false } };
                offset += size;
                break :blk .{ .file = .{ .at = at, .exec = f.exec } };
            },
        };
        const parent = try root.dir(a, parts.items[0 .. parts.items.len - 1]);
        try parent.entries.put(a, parts.items[parts.items.len - 1], .{ .leaf = leaf });
    }
    fw.interface.flush() catch return ev.fail(.io, pos, "cannot write the spool of a Git tree", .{});
    const root_node = try root.node(a);
    owned = false;
    var tree = spool.Tree.spooled(ev.gpa, ev.io, file, arena, root_node);
    var tree_owned = true;
    defer if (tree_owned) tree.deinit();
    var h: hash_mod.Hasher = .init(.sha256);
    var hb: [64 << 10]u8 = undefined;
    var hw = h.writer(&hb);
    tree.dump(&hw.interface, &d) catch return ev.fail(.io, pos, "{s}", .{d.message()});
    const hash = h.finish();
    const sp = treestore.storePath(name, hash, &d) catch return ev.fail(.io, pos, "{s}", .{d.message()});
    if (validInStore(ev, &sp, .recursive, hash)) {
        try adoptStore(ev, &sp);
        return .{ .path = sp, .hash = hash };
    }
    const s = ev.config.inputs orelse return ev.fail(.io, pos, "iets has no cache directory to hold a Git tree", .{});
    const entry = s.get(sp.baseName()) orelse blk: {
        var staged = s.stage(sp.baseName()) orelse return ev.fail(.io, pos, "iets has no cache directory to hold a Git tree", .{});
        var why: treestore.Rejected = undefined;
        tree_owned = false;
        break :blk s.put(name, .recursive, hash, &staged, &tree, &why, &d) catch return switch (why) {
            .io => ev.fail(.io, pos, "{s}", .{d.message()}),
            else => ev.fail(.io, pos, "iets cannot keep a Git tree in the input store", .{}),
        };
    };
    try adopt(ev, &sp, entry);
    return .{ .path = sp, .hash = hash };
}

/// tarball.cc:downloadFile for `builtins.fetchurl`: the bytes `url` serves,
/// as the flat fixed output `name` whose bytes hash to `expected`. The path
/// is known before the download, so `/nix/store` or the input store may hold
/// it already, as primops/fetchTree.cc:fetch checks first. Not substituted,
/// as in Nix (NixOS/nix#4313).
pub fn fetchFile(ev: *Evaluator, url: []const u8, name: []const u8, expected: Hash, pos: Pos) Error!StorePath {
    var d: Diag = .init(ev.gpa);
    defer d.deinit();
    const sp = treestore.filePath(name, expected, &d) catch return ev.fail(.eval, pos, "{s}", .{d.message()});
    if (validInStore(ev, &sp, .flat, expected)) {
        try adoptStore(ev, &sp);
        return sp;
    }
    const store = ev.config.inputs;
    if (store) |s| if (s.get(sp.baseName())) |entry| {
        try adoptFile(ev, &sp, entry);
        return sp;
    };
    const a = ev.local.arena.allocator();
    const shown = try http.shown(a, url);
    const s = store orelse return ev.fail(.eval, pos, "unable to download '{s}': iets has no cache directory to hold it", .{shown});
    const lk = s.fetchLock(sp.baseName(), Waiting{ .ev = ev, .what = try std.fmt.allocPrint(a, "iets: waiting for another process to download '{s}'", .{shown}) });
    defer if (lk) |l| s.unlock(l);
    if (s.reopen(sp.baseName())) |entry| {
        try adoptFile(ev, &sp, entry);
        return sp;
    }
    var staged = s.stage(sp.baseName()) orelse return ev.fail(.eval, pos, "unable to download '{s}': iets has no cache directory to hold it", .{shown});
    const file = spool.spoolFile(ev.io, staged.dir) catch |e| {
        staged.deinit();
        return ev.fail(.eval, pos, "unable to download '{s}': {f}", .{ shown, http.ioText(e) });
    };
    var wbuf: [64 << 10]u8 = undefined;
    var fw = file.writer(ev.io, &wbuf);
    _ = http.get(httpContext(ev), url, &.{}, false, &fw.interface, &d) catch |e| {
        file.close(ev.io);
        staged.deinit();
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.FetchFailed => ev.fail(.eval, pos, "unable to download '{s}': {s}", .{ shown, d.message() }),
        };
    };
    fw.interface.flush() catch {
        file.close(ev.io);
        staged.deinit();
        return ev.fail(.eval, pos, "unable to download '{s}': cannot write the download", .{shown});
    };
    var tree = spool.Tree.file(ev.gpa, ev.io, file, &d) catch {
        staged.deinit();
        return ev.fail(.eval, pos, "unable to download '{s}': {s}", .{ shown, d.message() });
    };
    var why: treestore.Rejected = undefined;
    const entry = s.put(name, .flat, expected, &staged, &tree, &why, &d) catch return switch (why) {
        .mismatch => |got| {
            var eb: [Hash.max_string_len]u8 = undefined;
            var gb: [Hash.max_string_len]u8 = undefined;
            // primops/fetchTree.cc:fetch
            var sb: [Hash.max_string_len]u8 = undefined;
            const hint = try std.fmt.allocPrint(a, "set sha256 to '{s}'", .{got.print(&sb, .sri, true)});
            return ev.failHint(.hash_mismatch, pos, hint, "hash mismatch in file downloaded from '{s}':\n  specified: {s}\n  got:       {s}", .{ shown, expected.print(&eb, .nix32, true), got.print(&gb, .nix32, true) });
        },
        .io => ev.fail(.eval, pos, "unable to download '{s}': {s}", .{ shown, d.message() }),
        .unstorable => ev.fail(.eval, pos, "unable to download '{s}': iets cannot keep it in the input store", .{shown}),
    };
    try adoptFile(ev, &sp, entry);
    return sp;
}

/// The last shell-out: a `git` or `hg` input needs a repository, which iets
/// cannot clone yet, so its locked attrs go to Nix's own `fetchTree` and the
/// store path Nix reports must be the one the lock implies.
fn fetchWithNix(ev: *Evaluator, full: []const u8, name: []const u8, attrs: *const Attrs, pos: Pos) Error!void {
    const a = ev.local.arena.allocator();
    const expr = try std.fmt.allocPrint(a, "(builtins.fetchTree (builtins.fromJSON {s})).outPath", .{try nixStringLiteral(a, try source.attrsToJson(a, attrs))});
    const missing = try std.fmt.allocPrint(a, "iets: input '{s}' is not in the store and nix is not on PATH; fetch it with nix ({s}) first", .{ name, try source.toUrl(a, attrs) });
    const r = try nixEval(ev, try std.fmt.allocPrint(a, "input '{s}'", .{name}), expr, missing, false, pos);
    if (!r.ok) {
        const url = try source.toUrl(a, attrs);
        // fetchers.cc:Input::checkLocks
        const ty = strAttr(attrs, "type") orelse "";
        if (std.mem.eql(u8, ty, "git") and std.mem.indexOf(u8, r.said, "NAR hash mismatch in input") != null)
            return ev.failHint(.hash_mismatch, pos, "git gave a different tree than the lock names: a .gitattributes filter (such as git-lfs), 'export-subst' or a submodule can cause that; fix it, or run 'nix flake update' to lock the tree git gives", "iets: nix could not fetch input '{s}' ({s})", .{ name, url });
        return ev.fail(.eval, pos, "iets: nix could not fetch input '{s}' ({s})", .{ name, url });
    }
    const got = std.mem.trim(u8, r.stdout, " \t\r\n");
    if (!std.mem.eql(u8, got, full))
        return ev.fail(.eval, pos, "iets: nix fetched '{f}' for input '{s}' but the lock implies '{s}'", .{ @import("../syntax/text.zig").lossy(got), name, full });
}

/// `builtins.fetchGit` of a commit, run by Nix: `args` are the call's
/// attributes, `shown` is the input as Nix names it. Returns the result's
/// attributes, with the store path as `outPath`.
pub fn fetchGitWithNix(ev: *Evaluator, args: *const Attrs, shown: []const u8, pos: Pos) Error!Attrs {
    const a = ev.local.arena.allocator();
    const expr = try std.fmt.allocPrint(a, "let r = builtins.fetchGit (builtins.fromJSON {s}); in builtins.toJSON (builtins.removeAttrs r [ \"outPath\" ] // {{ path = r.outPath; }})", .{try nixStringLiteral(a, try source.attrsToJson(a, args))});
    const missing = try std.fmt.allocPrint(a, "iets: builtins.fetchGit of '{s}' needs nix on PATH", .{shown});
    const what = try std.fmt.allocPrint(a, "the Git repository '{s}'", .{shown});
    const r = try nixEval(ev, what, expr, missing, true, pos);
    if (!r.ok) {
        if (std.mem.lastIndexOf(u8, r.said, "error: ")) |i|
            return ev.fail(.eval, pos, "{s}", .{std.mem.trim(u8, r.said[i + 7 ..], " \t\r\n")});
        return ev.fail(.eval, pos, "iets: nix could not fetch {s}", .{what});
    }
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, r.stdout, .{}) catch |e|
        return ev.fail(.eval, pos, "iets: nix said: {t}", .{e});
    if (v != .object) return ev.fail(.eval, pos, "iets: nix said: invalid type: expected a map", .{});
    var out: Attrs = .{};
    var it = v.object.iterator();
    while (it.next()) |kv| {
        const k = if (std.mem.eql(u8, kv.key_ptr.*, "path")) "outPath" else kv.key_ptr.*;
        const val: AttrVal = switch (kv.value_ptr.*) {
            .string => |s| .{ .str = s },
            .bool => |b| .{ .bool = b },
            .integer => |n| if (n >= 0) .{ .int = @intCast(n) } else continue,
            else => continue,
        };
        try out.put(a, k, val);
    }
    return out;
}

const NixEval = struct { ok: bool, stdout: []const u8, said: []const u8 };

/// `nix eval --raw --impure --expr EXPR` for a fetch of `what`, its records
/// relayed, its errors only into what it said when `keep_errors` is set:
/// whether it succeeded, its stdout and what it said.
fn nixEval(ev: *Evaluator, what: []const u8, expr: []const u8, missing: []const u8, keep_errors: bool, pos: Pos) Error!NixEval {
    const a = ev.local.arena.allocator();
    const session = ev.config.session;
    if (session) |s| if (s.settings.fetching)
        return ev.fail(.eval, pos, "iets: recursive fetch of {s}: the nix on PATH is iets itself", .{what});
    const envv: env_mod.Env = if (session) |s| s.env else .{};
    const nix_dir = if (session) |s| s.settings.nix_bin_dir else null;
    const nix = nixbin.real(a, ev.io, envv, nix_dir, "nix") orelse return ev.fail(.eval, pos, "{s}", .{missing});
    const lg: ?*log_mod.Log = if (session) |s| &s.log else null;
    const act: ?log_mod.Activity = if (lg) |l| l.activity(0, log_mod.lvl_talkative, log_mod.act_fetch_tree, try std.fmt.allocPrint(a, "fetching {s} with nix", .{what}), &.{}) else null;
    defer if (act) |x| x.end();
    // git may ask for credentials on the terminal, as under Nix
    if (lg) |l| l.@"suspend"();
    defer if (lg) |l| l.unsuspend();
    var env = env_mod.with(a, envv, &.{.{ "IETS_FETCHING", "1" }}) catch return error.OutOfMemory;
    if (envv.map == null) {
        env = try proc.processEnv(a);
        try env.put("IETS_FETCHING", "1");
    }
    var child = std.process.spawn(ev.io, .{
        .argv = &.{ nix, "--extra-experimental-features", "nix-command flakes", "--log-format", "internal-json", "eval", "--raw", "--impure", "--expr", expr },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| return ev.fail(.io, pos, "iets: cannot run nix to fetch {s}: {f}", .{ what, http.ioText(e) });
    defer child.kill(ev.io);
    const Reader = struct {
        fn go(io: Io, f: Io.File, out: *std.ArrayList(u8), gpa: Allocator) void {
            var buf: [16 << 10]u8 = undefined;
            var r = f.readerStreaming(io, &.{});
            while (true) {
                const n = r.interface.readSliceShort(&buf) catch break;
                if (n == 0) break;
                out.appendSlice(gpa, buf[0..n]) catch break;
            }
        }
    };
    var stdout: std.ArrayList(u8) = .empty;
    defer stdout.deinit(ev.gpa);
    const t = std.Thread.spawn(.{}, Reader.go, .{ ev.io, child.stdout.?, &stdout, ev.gpa }) catch
        return ev.fail(.io, pos, "iets: cannot run nix to fetch {s}: cannot start a thread", .{what});
    const said = try relay(ev, child.stderr.?, if (act) |x| x.id else 0, keep_errors);
    t.join();
    const term = child.wait(ev.io) catch |e| return ev.fail(.io, pos, "iets: cannot run nix to fetch {s}: {t}", .{ what, e });
    const ok = switch (term) {
        .exited => |c| c == 0,
        else => false,
    };
    return .{ .ok = ok, .stdout = try a.dupe(u8, stdout.items), .said = said };
}

/// Nix's records go under `act`; git's `\r` redraws go to a terminal as they
/// are, as under Nix, or into `act`'s detail. With `keep_errors` an error
/// is not printed: its innermost message goes into the text, after
/// `error: `. Returns the text.
fn relay(ev: *Evaluator, from: Io.File, act: u64, keep_errors: bool) Error![]const u8 {
    const a = ev.local.arena.allocator();
    const lg: ?*log_mod.Log = if (ev.config.session) |s| &s.log else null;
    const terminal = if (lg) |l| l.progress.mode() == .bar and !l.isJson() else false;
    var said: std.ArrayList(u8) = .empty;
    var ids: std.AutoHashMapUnmanaged(u64, u64) = .empty;
    defer ids.deinit(ev.gpa);
    var seg: std.ArrayList(u8) = .empty;
    defer seg.deinit(ev.gpa);
    var buf: [16 << 10]u8 = undefined;
    var r = from.readerStreaming(ev.io, &.{});
    var tmp: std.heap.ArenaAllocator = .init(ev.gpa);
    defer tmp.deinit();
    outer: while (true) {
        const n = r.interface.readSliceShort(&buf) catch break;
        if (n == 0) break;
        for (buf[0..n]) |b| {
            if (b != '\n' and b != '\r') {
                try seg.append(ev.gpa, b);
                continue;
            }
            _ = tmp.reset(.retain_capacity);
            const ta = tmp.allocator();
            const text = try std.fmt.allocPrint(ta, "{f}", .{@import("../syntax/text.zig").lossy(seg.items)});
            seg.clearRetainingCapacity();
            if (b == '\r') {
                if (lg) |l| {
                    if (terminal) {
                        l.err(try std.fmt.allocPrint(ta, "{s}\r", .{text}));
                    } else l.detail(act, std.mem.trim(u8, text, " \t"));
                }
                continue;
            }
            const v: ?std.json.Value = if (std.mem.startsWith(u8, text, "@nix "))
                std.json.parseFromSliceLeaky(std.json.Value, ta, text[5..], .{}) catch null
            else
                null;
            if (v == null or v.? != .object) {
                if (text.len > 0) {
                    line(ev, text);
                    try said.appendSlice(a, text);
                    try said.append(a, '\n');
                }
                continue;
            }
            const o = v.?.object;
            const num = struct {
                fn f(m: std.json.ObjectMap, k: []const u8) u64 {
                    const x = m.get(k) orelse return 0;
                    return if (x == .integer and x.integer >= 0) @intCast(x.integer) else 0;
                }
            }.f;
            const str = struct {
                fn f(m: std.json.ObjectMap, k: []const u8) ?[]const u8 {
                    const x = m.get(k) orelse return null;
                    return if (x == .string) x.string else null;
                }
            }.f;
            const action = str(o, "action") orelse continue;
            const l = lg orelse {
                if (std.mem.eql(u8, action, "msg")) {
                    const msg = str(o, "msg") orelse "";
                    if (keep_errors and num(o, "level") == 0) {
                        const raw = str(o, "raw_msg") orelse msg;
                        try said.appendSlice(a, "error: ");
                        try said.appendSlice(a, try log_mod.stripAnsi(ta, raw));
                        try said.append(a, '\n');
                        continue :outer;
                    }
                    line(ev, msg);
                    try said.appendSlice(a, msg);
                    try said.append(a, '\n');
                }
                continue;
            };
            if (std.mem.eql(u8, action, "start")) {
                const id = l.activityId();
                try ids.put(ev.gpa, num(o, "id"), id);
                const up = ids.get(num(o, "parent")) orelse act;
                l.start(id, num(o, "level"), num(o, "type"), str(o, "text") orelse "", try fields(ta, o), up);
            } else if (std.mem.eql(u8, action, "stop")) {
                if (ids.fetchRemove(num(o, "id"))) |kv| l.stop(kv.value);
            } else if (std.mem.eql(u8, action, "result")) {
                if (ids.get(num(o, "id"))) |id| l.result(id, num(o, "type"), try fields(ta, o));
            } else if (std.mem.eql(u8, action, "msg")) {
                const msg = str(o, "msg") orelse "";
                if (keep_errors and num(o, "level") == 0) {
                    const raw = str(o, "raw_msg") orelse msg;
                    try said.appendSlice(a, "error: ");
                    try said.appendSlice(a, try log_mod.stripAnsi(ta, raw));
                    try said.append(a, '\n');
                    continue;
                }
                line(ev, msg);
                try said.appendSlice(a, msg);
                try said.append(a, '\n');
            }
        }
    }
    if (lg) |l| {
        var it = ids.valueIterator();
        while (it.next()) |id| l.stop(id.*);
    }
    return said.items;
}

/// `log::line`: a line on stderr through the run's log.
fn line(ev: *Evaluator, text: []const u8) void {
    ev.log("{s}", .{text});
}

/// A record's `fields` as the log takes them.
fn fields(a: Allocator, o: std.json.ObjectMap) Allocator.Error![]const log_mod.Field {
    const f = o.get("fields") orelse return &.{};
    if (f != .array) return &.{};
    var out: std.ArrayList(log_mod.Field) = .empty;
    for (f.array.items) |x| switch (x) {
        .string => |s| try out.append(a, .{ .str = s }),
        .integer => |n| try out.append(a, .{ .int = @intCast(n) }),
        else => {},
    };
    return out.items;
}

const testing = std.testing;

test "a nix string literal escapes" {
    const a = testing.allocator;
    const s = try nixStringLiteral(a, "{\"a\":\"x\\\"y${z}\\\\\"}");
    defer a.free(s);
    try testing.expectEqualStrings("\"{\\\"a\\\":\\\"x\\\\\\\"y\\${z}\\\\\\\\\\\"}\"", s);
}

fn testAttrs(a: Allocator, pairs: []const [2][]const u8) !Attrs {
    var m: Attrs = .{};
    for (pairs) |p| try m.put(a, p[0], .{ .str = p[1] });
    return m;
}

fn testConf(a: Allocator, text: []const u8) !config.Config {
    var c: config.Config = .empty(a, testing.io, .{});
    var d: Diag = .init(a);
    try c.apply(text, "test", &d);
    return c;
}

const REV = "b1d9ab70662946ef0850d488da1c9019f3a9752a";

fn expectDl(want_url: []const u8, want_headers: []const [2][]const u8, got: Download) !void {
    try testing.expectEqualStrings(want_url, got.url);
    try testing.expectEqual(want_headers.len, got.headers.len);
    for (want_headers, got.headers) |w, g| {
        try testing.expectEqualStrings(w[0], g.name);
        try testing.expectEqualStrings(w[1], g.value);
    }
}

test "download urls match the fetchers" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diag = .init(a);
    const none = try testConf(a, "");
    var gh = try testAttrs(a, &.{ .{ "type", "github" }, .{ "owner", "numtide" }, .{ "repo", "flake-utils" }, .{ "rev", REV } });
    try expectDl("https://github.com/numtide/flake-utils/archive/" ++ REV ++ ".tar.gz", &.{}, try tarballUrl(a, &none, &gh, &d));
    // A token moves github.com to the API endpoint (github.cc:getDownloadUrl).
    const tok = try testConf(a, "access-tokens = github.com=T");
    try expectDl("https://api.github.com/repos/numtide/flake-utils/tarball/" ++ REV, &.{.{ "Authorization", "token T" }}, try tarballUrl(a, &tok, &gh, &d));
    var ghe = try gh.clone(a);
    try ghe.put(a, "host", .{ .str = "git.corp" });
    try testing.expectEqualStrings("https://git.corp/api/v3/repos/numtide/flake-utils/tarball/" ++ REV, (try tarballUrl(a, &none, &ghe, &d)).url);

    var gl = try testAttrs(a, &.{ .{ "type", "gitlab" }, .{ "owner", "o" }, .{ "repo", "r" }, .{ "rev", REV } });
    const pat = try testConf(a, "access-tokens = gitlab.com=PAT:T");
    try expectDl("https://gitlab.com/api/v4/projects/o%2Fr/repository/archive.tar.gz?sha=" ++ REV, &.{.{ "Private-token", "T" }}, try tarballUrl(a, &pat, &gl, &d));
    const oauth = try testConf(a, "access-tokens = gitlab.com=OAuth2:T");
    const g2 = try tarballUrl(a, &oauth, &gl, &d);
    try testing.expectEqualStrings("Bearer T", g2.headers[0].value);

    var sh = try testAttrs(a, &.{ .{ "type", "sourcehut" }, .{ "owner", "~o" }, .{ "repo", "r" }, .{ "rev", REV } });
    const srht = try testConf(a, "access-tokens = git.sr.ht=T");
    try expectDl("https://git.sr.ht/~o/r/archive/" ++ REV ++ ".tar.gz", &.{.{ "Authorization", "Bearer T" }}, try tarballUrl(a, &srht, &sh, &d));

    var tb = try testAttrs(a, &.{ .{ "type", "tarball" }, .{ "url", "https://x.example/a.tar.xz" } });
    try expectDl("https://x.example/a.tar.xz", &.{}, try tarballUrl(a, &none, &tb, &d));
    var bad = try testAttrs(a, &.{.{ "type", "github" }});
    try testing.expectError(error.Bad, tarballUrl(a, &none, &bad, &d));
}

test "access tokens match the longest prefix" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try testConf(a, "access-tokens = github.com=host github.com/a=owner github.com/a/b=repo github.com/ab=other");
    try testing.expectEqualStrings("repo", accessToken(&c, "github.com", "github.com/a/b").?);
    try testing.expectEqualStrings("owner", accessToken(&c, "github.com", "github.com/a/c").?);
    try testing.expectEqualStrings("other", accessToken(&c, "github.com", "github.com/ab/c").?);
    try testing.expectEqualStrings("host", accessToken(&c, "github.com", "github.com/z/y").?);
    try testing.expect(accessToken(&c, "gitlab.com", "gitlab.com/z/y") == null);
}

test "only the archive types are fetched by iets" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]struct { []const u8, bool }{ .{ "github", true }, .{ "gitlab", true }, .{ "sourcehut", true }, .{ "tarball", true }, .{ "git", false }, .{ "hg", false }, .{ "path", false }, .{ "file", false } }) |c| {
        var m = try testAttrs(a, &.{.{ "type", c[0] }});
        try testing.expectEqual(c[1], isTarballType(&m));
    }
}

const Answer = struct {
    v: ?bool,
    pub fn call(x: @This()) ?bool {
        return x.v;
    }
};

const Panics = struct {
    pub fn call(_: @This()) ?bool {
        @panic("a missing path needs no store");
    }
};

test "a leftover is not a valid path" {
    const io = testing.io;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "tree");
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/f", .data = "hi\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "hi\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const p = struct {
        fn f(b: []const u8, n: []const u8) ![]u8 {
            return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ b, n });
        }
    }.f;
    const file = try p(base, "file");
    defer gpa.free(file);
    const tree = try p(base, "tree");
    defer gpa.free(tree);
    const gone = try p(base, "gone");
    defer gpa.free(gone);
    const flat = hash_mod.hashBytes(.sha256, "hi\n");
    var d: Diag = .init(gpa);
    defer d.deinit();
    const th = try nar.narHash(gpa, io, Io.Dir.cwd(), tree, &d);
    const no: Answer = .{ .v = null };
    try testing.expectEqual(hooks.Kind.regular, validKind(gpa, io, file, .flat, flat, no).?);
    try testing.expectEqual(hooks.Kind.directory, validKind(gpa, io, tree, .recursive, th, no).?);
    try testing.expect(validKind(gpa, io, tree, .flat, flat, no) == null);
    try testing.expect(validKind(gpa, io, file, .recursive, th, no) == null);
    try testing.expect(validKind(gpa, io, file, .flat, flat, Answer{ .v = false }) == null);
    try testing.expectEqual(hooks.Kind.regular, validKind(gpa, io, file, .flat, th, Answer{ .v = true }).?);
    try testing.expect(validKind(gpa, io, gone, .flat, flat, Panics{}) == null);
    try tmp.dir.writeFile(io, .{ .sub_path = "file", .data = "half" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tree/f", .data = "half" });
    try testing.expect(validKind(gpa, io, file, .flat, flat, no) == null);
    try testing.expect(validKind(gpa, io, tree, .recursive, th, no) == null);
}
