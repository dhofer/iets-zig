//! Flake references (flakeref.cc, the github, gitlab, git, path, tarball,
//! file and indirect schemes' inputFromURL and toURL) for the builtins, the
//! command line and fetchTree's messages. Valid input gives Nix's output;
//! checks that only refuse invalid input are left out
//! (docs/reference/divergences.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const attrs_mod = @import("../source/attrs.zig");
const AttrVal = attrs_mod.AttrVal;
const Attrs = attrs_mod.Attrs;
const StrMap = attrs_mod.StrMap;
const strAttr = attrs_mod.strAttr;
const hash = @import("../store/hash.zig");

/// `Flake` is an invalid reference (or a bad hash), `Unsupported` a
/// reference Nix takes and iets does not.
pub const Error = error{ Flake, Unsupported, OutOfMemory };

const Query = StrMap([]const u8);

fn unsupported(d: *Diag, comptime fmt: []const u8, args: anytype) Error {
    return d.fail(error.Unsupported, fmt ++ " is not supported", args);
}

const Url = struct {
    scheme: []const u8,
    /// `user@host:port` as url.cc renders it.
    authority: ?[]const u8 = null,
    path: std.ArrayList([]const u8) = .empty,
    query: Query = .{},
    fragment: []const u8 = "",

    pub fn format(u: *const Url, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:", .{u.scheme});
        if (u.authority) |a| try w.print("//{s}", .{a});
        for (u.path.items, 0..) |s, i| {
            if (i > 0) try w.writeByte('/');
            try encode(w, s, ":@");
        }
        for (u.query.items(), 0..) |e, i| {
            try w.writeByte(if (i == 0) '?' else '&');
            try encode(w, e.key, ":@/?");
            try w.writeByte('=');
            try encode(w, e.value, ":@/?");
        }
        if (u.fragment.len > 0) {
            try w.writeByte('#');
            try encode(w, u.fragment, "");
        }
    }

    fn toString(u: *const Url, a: Allocator) Error![]const u8 {
        return std.fmt.allocPrint(a, "{f}", .{u});
    }
};

fn splitPath(a: Allocator, s: []const u8) Error!std.ArrayList([]const u8) {
    var l: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |p| try l.append(a, p);
    return l;
}

fn unreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "-._~", c) != null;
}

/// url.cc:percentEncode.
fn encode(w: *std.Io.Writer, s: []const u8, keep: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        if (unreserved(c) or std.mem.indexOfScalar(u8, keep, c) != null) {
            try w.writeByte(c);
        } else try w.print("%{X:0>2}", .{c});
    }
}

fn decode(a: Allocator, s: []const u8, d: *Diag) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var parts = std.mem.splitScalar(u8, s, '%');
    try out.appendSlice(a, parts.first());
    while (parts.next()) |p| {
        // a leading '+' passes as a sign, as Rust iets decodes it
        const c: ?u8 = if (p.len < 2) null else if (p[0] == '+')
            std.fmt.charToDigit(p[1], 16) catch null
        else
            std.fmt.parseInt(u8, p[0..2], 16) catch null;
        if (c == null or p[0] == '_' or p[1] == '_')
            return d.fail(error.Flake, "invalid percent-encoding in '{s}'", .{s});
        try out.append(a, c.?);
        try out.appendSlice(a, p[2..]);
    }
    return @import("../syntax/text.zig").lossyAlloc(a, out.items);
}

/// url.cc:decodeQuery: a parameter without `=` goes, the first of two wins.
fn decodeQuery(a: Allocator, q: []const u8, d: *Diag) Error!Query {
    var res: Query = .{};
    var it = std.mem.splitScalar(u8, q, '&');
    while (it.next()) |p| {
        const at = std.mem.indexOfScalar(u8, p, '=') orelse continue;
        const k = try decode(a, p[0..at], d);
        const v = try decode(a, p[at + 1 ..], d);
        try res.putFirst(a, k, v);
    }
    return res;
}

/// url.cc:parseUrlScheme: `(application+)?transport`.
const Scheme = struct { app: ?[]const u8, transport: []const u8 };

fn splitScheme(s: []const u8) Scheme {
    const i = std.mem.indexOfScalar(u8, s, '+') orelse return .{ .app = null, .transport = s };
    return .{ .app = s[0..i], .transport = s[i + 1 ..] };
}

fn isScheme(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "+-.", c) == null) return false;
    return true;
}

fn listed(comptime list: []const u8, k: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ' ');
    while (it.next()) |x| if (std.mem.eql(u8, x, k)) return true;
    return false;
}

fn eq(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

/// url.cc:parseURL, without boost.url's character checks.
fn parseUrl(a: Allocator, s: []const u8, d: *Diag) Error!Url {
    const colon = std.mem.indexOfScalar(u8, s, ':');
    if (colon == null or !isScheme(s[0..colon.?])) return unsupported(d, "URL '{s}'", .{s});
    const scheme = s[0..colon.?];
    var rest = s[colon.? + 1 ..];
    var fragment: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| {
        fragment = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var query: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
        query = rest[i + 1 ..];
        rest = rest[0..i];
    }
    var auth: ?[]const u8 = null;
    var path = rest;
    if (std.mem.startsWith(u8, rest, "//")) {
        const r = rest[2..];
        const i = std.mem.indexOfScalar(u8, r, '/') orelse r.len;
        auth = try authority(a, r[0..i], d);
        path = r[i..];
    }
    if (path.len == 0 and std.mem.eql(u8, splitScheme(scheme).transport, "file")) path = "/";
    var u: Url = .{ .scheme = scheme, .authority = auth };
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |p| try u.path.append(a, try decode(a, p, d));
    u.query = try decodeQuery(a, query, d);
    u.fragment = try decode(a, fragment, d);
    return u;
}

/// An authority of unreserved characters, with the port as a number.
fn authority(a: Allocator, s: []const u8, d: *Diag) Error![]const u8 {
    var user: ?[]const u8 = null;
    var hp = s;
    if (std.mem.lastIndexOfScalar(u8, s, '@')) |i| {
        user = s[0..i];
        hp = s[i + 1 ..];
    }
    var host = hp;
    var port: []const u8 = "";
    if (std.mem.indexOfScalar(u8, hp, ':')) |i| {
        host = hp[0..i];
        port = hp[i + 1 ..];
    }
    const n: u16 = parseUnsigned(u16, port) orelse 0;
    for (s) |c| if (!unreserved(c) and c != ':' and c != '@') return unsupported(d, "URL authority '{s}'", .{s});
    if ((n == 0) != (port.len == 0)) return unsupported(d, "URL authority '{s}'", .{s});
    var out: std.Io.Writer.Allocating = .init(a);
    if (user) |u| out.writer.print("{s}@", .{u}) catch return error.OutOfMemory;
    out.writer.writeAll(host) catch return error.OutOfMemory;
    if (n > 0) out.writer.print(":{d}", .{n}) catch return error.OutOfMemory;
    return out.written();
}

/// Decimal digits with an optional leading `+`, the form Rust iets accepts.
fn parseUnsigned(comptime Int: type, s: []const u8) ?Int {
    const t = if (std.mem.startsWith(u8, s, "+")) s[1..] else s;
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(Int, t, 10) catch null;
}

/// Runs of `/` as one, what pathToUrlPath then urlPathToPath leave.
fn collapse(a: Allocator, p: []const u8) Error![]const u8 {
    if (std.mem.indexOf(u8, p, "//") == null) return p;
    var out: std.ArrayList(u8) = .empty;
    for (p, 0..) |c, i| {
        if (c == '/' and i > 0 and p[i - 1] == '/') continue;
        try out.append(a, c);
    }
    return out.items;
}

pub fn isRev(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// A query parameter as an attribute; a `revCount` that is no number goes.
fn putAttr(a: Allocator, m: *Attrs, k: []const u8, v: []const u8) Error!void {
    if (std.mem.eql(u8, k, "revCount") or std.mem.eql(u8, k, "lastModified")) {
        try m.put(a, k, .{ .int = parseUnsigned(u64, v) orelse return });
    } else try m.put(a, k, .{ .str = v });
}

/// fetchers.cc:Input::getRev, as 40 hex digits.
fn rev(a: Allocator, m: *const Attrs, d: *Diag) Error!?[]const u8 {
    const s = strAttr(m, "rev") orelse return null;
    const h = hash.Hash.parseAny(s, null, d) catch
        hash.Hash.parseAny(s, .sha1, d) catch return error.Flake;
    const buf = try a.alloc(u8, hash.Hash.max_string_len);
    return h.print(buf, .base16, false);
}

/// fetchers.cc:Input::getNarHash: an empty one is the zero hash.
fn narHash(m: *const Attrs) ?[]const u8 {
    const h = strAttr(m, "narHash") orelse return null;
    return if (h.len == 0) "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" else h;
}

fn pathInput(a: Allocator, path: []const u8, query: *const Query) Error!Attrs {
    var m: Attrs = .{};
    try m.put(a, "type", .{ .str = "path" });
    try m.put(a, "path", .{ .str = path });
    for (query.items()) |e| try putAttr(a, &m, e.key, e.value);
    return m;
}

fn segments(a: Allocator, path: []const []const u8) Error![]const []const u8 {
    var l: std.ArrayList([]const u8) = .empty;
    for (path) |s| if (s.len > 0) try l.append(a, s);
    return l.items;
}

/// indirect.cc:inputFromURL: `ID[/REF][/REV]`.
fn indirect(a: Allocator, p: []const []const u8, shown: []const u8, d: *Diag) Error!Attrs {
    var ref: ?[]const u8 = null;
    var rv: ?[]const u8 = null;
    switch (p.len) {
        1 => {},
        2 => if (isRev(p[1])) {
            rv = p[1];
        } else {
            ref = p[1];
        },
        3 => {
            ref = p[1];
            rv = p[2];
        },
        else => return d.fail(error.Flake, "flake URL '{s}' is not ID[/REF][/REV]", .{shown}),
    }
    var m: Attrs = .{};
    try m.put(a, "type", .{ .str = "indirect" });
    try m.put(a, "id", .{ .str = p[0] });
    if (ref) |r| try m.put(a, "ref", .{ .str = r });
    if (rv) |r| try m.put(a, "rev", .{ .str = try std.ascii.allocLowerString(a, r) });
    return m;
}

const curl_attrs = "url narHash name unpack rev revCount lastModified";
const git_flags = "shallow submodules lfs exportIgnore allRefs verifyCommit";

/// fetchers.cc:Input::fromURL with requireTree.
fn inputFromUrl(a: Allocator, url_in: Url, d: *Diag) Error!Attrs {
    var url = url_in;
    const scheme = url.scheme;
    const sc = splitScheme(scheme);
    var m: Attrs = .{};
    const curl = std.mem.eql(u8, sc.transport, "file") or std.mem.eql(u8, sc.transport, "http") or std.mem.eql(u8, sc.transport, "https");
    if (curl and (sc.app == null or eq(sc.app, "file") or eq(sc.app, "tarball"))) {
        // tarball.cc:CurlInputScheme::inputFromURL
        try m.put(a, "type", .{ .str = if (eq(sc.app, "file")) "file" else "tarball" });
        for ([_][]const u8{ "narHash", "rev", "revCount", "lastModified" }) |k|
            if (url.query.get(k)) |v| try putAttr(a, &m, k, v);
        var kept: Query = .{};
        for (url.query.items()) |e| if (!listed(curl_attrs, e.key)) try kept.put(a, e.key, e.value);
        url.query = kept;
    } else if (eq(sc.app, "git") or std.mem.eql(u8, scheme, "git")) {
        // git.cc:inputFromURL, then fixGitURL drops the `git+`
        try m.put(a, "type", .{ .str = "git" });
        var kept: Query = .{};
        for (url.query.items()) |e| {
            if (listed(git_flags, e.key)) {
                try m.put(a, e.key, .{ .bool = std.mem.eql(u8, e.value, "1") });
            } else if (listed("rev ref keytype publicKey publicKeys", e.key)) {
                try m.put(a, e.key, .{ .str = e.value });
            } else try kept.put(a, e.key, e.value);
        }
        url.query = kept;
    } else if (std.mem.eql(u8, scheme, "github") or std.mem.eql(u8, scheme, "gitlab")) {
        // github.cc:GitArchiveInputScheme::inputFromURL
        const p = try segments(a, url.path.items);
        if (p.len < 2) return d.fail(error.Flake, "URL '{f}' is invalid", .{&url});
        try m.put(a, "type", .{ .str = scheme });
        try m.put(a, "owner", .{ .str = p[0] });
        try m.put(a, "repo", .{ .str = p[1] });
        if (p.len > 2) {
            const k = if (p.len == 3 and isRev(p[2])) "rev" else "ref";
            try m.put(a, k, .{ .str = try std.mem.join(a, "/", p[2..]) });
        }
        for (url.query.items()) |e| {
            if (!listed("rev ref host narHash", e.key)) continue;
            if (m.contains(e.key)) {
                const what = if (std.mem.eql(u8, e.key, "rev")) "commit hashes" else "branch/tag names";
                return d.fail(error.Flake, "URL '{f}' contains multiple {s}", .{ &url, what });
            }
            try m.put(a, e.key, .{ .str = e.value });
        }
        // github.cc:inputFromAttrs
        if (strAttr(&m, "ref")) |r| if (strAttr(&m, "rev")) |v|
            return d.fail(error.Flake, "input '{f}' contains both a commit hash ('{s}') and a branch/tag name ('{s}')", .{ &url, v, r });
        return m;
    } else if (std.mem.eql(u8, scheme, "flake")) {
        return indirect(a, try segments(a, url.path.items), try url.toString(a), d);
    } else if (std.mem.eql(u8, scheme, "path")) {
        var p = try collapse(a, try std.mem.join(a, "/", url.path.items));
        if (p.len == 0) p = "/";
        return pathInput(a, p, &url.query);
    } else return unsupported(d, "flake reference scheme '{s}'", .{scheme});
    url.scheme = sc.transport;
    try m.put(a, "url", .{ .str = try url.toString(a) });
    return m;
}

/// The schemes' toURL.
fn toUrl(a: Allocator, m: *const Attrs, d: *Diag) Error!Url {
    const ty = strAttr(m, "type") orelse "";
    const ref = strAttr(m, "ref");
    var u: Url = undefined;
    const S = struct {
        fn get(mm: *const Attrs, k: []const u8, dd: *Diag) Error![]const u8 {
            return strAttr(mm, k) orelse dd.fail(error.Flake, "input attribute '{s}' is missing", .{k});
        }
    };
    if (std.mem.eql(u8, ty, "indirect")) {
        u = .{ .scheme = "flake" };
        try u.path.append(a, try S.get(m, "id", d));
    } else if (std.mem.eql(u8, ty, "github") or std.mem.eql(u8, ty, "gitlab")) {
        // github.cc:inputFromAttrs; written as a path, the two would read
        // back as one ref
        if (ref) |r| if (strAttr(m, "rev")) |v|
            return d.fail(error.Flake, "input contains both a commit hash ('{s}') and a branch/tag name ('{s}')", .{ v, r });
        u = .{ .scheme = ty };
        try u.path.append(a, try S.get(m, "owner", d));
        try u.path.append(a, try S.get(m, "repo", d));
    } else if (std.mem.eql(u8, ty, "path")) {
        u = .{ .scheme = "path", .path = try splitPath(a, try S.get(m, "path", d)) };
        for (m.items()) |e| {
            if (listed("path type __final", e.key)) continue;
            const v = switch (e.value) {
                .str => |s| s,
                .int => |n| try std.fmt.allocPrint(a, "{d}", .{n}),
                .bool => |b| if (b) "1" else "0",
            };
            try u.query.put(a, e.key, v);
        }
        return u;
    } else if (std.mem.eql(u8, ty, "git") or std.mem.eql(u8, ty, "tarball") or std.mem.eql(u8, ty, "file")) {
        u = try parseUrl(a, try S.get(m, "url", d), d);
    } else return unsupported(d, "flake reference type '{s}'", .{ty});

    if (std.mem.eql(u8, ty, "git")) {
        const t = if (std.mem.startsWith(u8, u.scheme, "git+")) u.scheme[4..] else u.scheme;
        u.scheme = if (std.mem.eql(u8, t, "git")) t else try std.mem.concat(a, u8, &.{ "git+", t });
        if (ref) |r| try u.query.put(a, "ref", r);
        if (try rev(a, m, d)) |r| try u.query.put(a, "rev", r);
        for ([_][]const u8{ "shallow", "lfs", "submodules", "exportIgnore", "verifyCommit" }) |k| {
            if (m.get(k)) |v| if (v == .bool and v.bool) try u.query.put(a, k, "1");
        }
        return u;
    }
    if (!std.mem.eql(u8, ty, "tarball") and !std.mem.eql(u8, ty, "file")) {
        if (ref) |r| try u.path.append(a, r);
        if (try rev(a, m, d)) |r| try u.path.append(a, r);
    }
    if (!std.mem.eql(u8, ty, "indirect")) if (narHash(m)) |h| try u.query.put(a, "narHash", h);
    if (std.mem.startsWith(u8, ty, "git")) if (strAttr(m, "host")) |h| try u.query.put(a, "host", h);
    return u;
}

/// url.cc:fixGitURL: a path becomes a `file:` URL and `git+` goes. An
/// SCP-like `user@host:path` is unsupported.
pub fn fixGitUrl(a: Allocator, s: []const u8, d: *Diag) Error![]const u8 {
    const before_slash = s[0 .. std.mem.indexOfScalar(u8, s, '/') orelse s.len];
    var scp = false;
    for (before_slash, 0..) |c, i| {
        if (c == '@' and std.mem.indexOfScalar(u8, s[i + 1 ..], ':') != null) scp = true;
    }
    if (!std.mem.startsWith(u8, s, "/") and scp) return unsupported(d, "SCP-like Git URL '{s}'", .{s});
    if (!std.mem.startsWith(u8, s, "file:") and !std.mem.startsWith(u8, s, "git+file:") and std.mem.indexOf(u8, s, "://") == null) {
        const path = try splitPath(a, s);
        if (std.mem.indexOfScalar(u8, path.items[0], ':') != null)
            return d.fail(error.Flake, "SCP-like URL '{s}' is not supported; use SSH URL syntax instead (ssh://...)", .{s});
        const u: Url = .{ .scheme = "file", .path = path, .authority = if (std.mem.startsWith(u8, s, "/")) "" else null };
        return u.toString(a);
    }
    var u = try parseUrl(a, s, d);
    const sc = splitScheme(u.scheme);
    if (eq(sc.app, "git")) u.scheme = sc.transport;
    return u.toString(a);
}

/// The path of a `file:` URL, as git.cc:getRepoInfo reads it. An authority
/// (`file://host/p`) names no path on this machine, so it has none.
pub fn fileUrlPath(a: Allocator, s: []const u8) Error!?[]const u8 {
    var d: Diag = .init(a);
    const u = parseUrl(a, s, &d) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!std.mem.eql(u8, u.scheme, "file") or (u.authority orelse @as([]const u8, "")).len != 0) return null;
    return try std.mem.join(a, "/", u.path.items);
}

/// A parsed flake reference; `bare` is a path without a scheme.
pub const Parsed = struct {
    input: Attrs,
    dir: []const u8,
    fragment: []const u8,
    bare: bool,
};

/// Whether a location is a registry reference: `ID[/REF-OR-REV...]`.
pub fn isIndirect(loc_in: []const u8) bool {
    const loc = if (std.mem.startsWith(u8, loc_in, "flake:")) loc_in[6..] else loc_in;
    const slash = std.mem.indexOfScalar(u8, loc, '/');
    const id = loc[0 .. slash orelse loc.len];
    if (id.len == 0 or !std.ascii.isAlphabetic(id[0])) return false;
    for (id[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    const r = loc[(slash orelse return true) + 1 ..];
    if (r.len == 0 or !(std.ascii.isAlphanumeric(r[0]) or r[0] == '@')) return false;
    for (r) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_./@+-", c) == null) return false;
    return true;
}

/// flakeref.cc:parseFlakeRefWithFragment without a base directory.
pub fn parse(a: Allocator, s: []const u8, d: *Diag) Error!Parsed {
    const hash_at = std.mem.indexOfScalar(u8, s, '#');
    const loc = s[0 .. hash_at orelse s.len];
    const frag = if (hash_at) |i| s[i + 1 ..] else "";
    const id = !std.mem.startsWith(u8, loc, "flake:") and isIndirect(loc);
    const has_scheme = if (std.mem.indexOfScalar(u8, s, ':')) |i| isScheme(s[0..i]) else false;
    const bare = !id and !has_scheme;
    if (id) {
        var path: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, loc, '/');
        while (it.next()) |p| if (p.len > 0) try path.append(a, p);
        return .{ .input = try indirect(a, path.items, loc, d), .dir = "", .fragment = try decode(a, frag, d), .bare = false };
    }
    if (bare) {
        const q = std.mem.indexOfScalar(u8, loc, '?');
        var query = try decodeQuery(a, if (q) |i| loc[i + 1 ..] else "", d);
        const dir = query.remove("dir") orelse "";
        const input = try pathInput(a, try collapse(a, loc[0 .. q orelse loc.len]), &query);
        return .{ .input = input, .dir = dir, .fragment = try decode(a, frag, d), .bare = true };
    }
    var url = try parseUrl(a, s, d);
    const dir = url.query.remove("dir") orelse "";
    const fragment = url.fragment;
    url.fragment = "";
    return .{ .input = try inputFromUrl(a, url, d), .dir = dir, .fragment = fragment, .bare = false };
}

/// flake-primops.cc: no base directory, so a relative path is an error.
pub fn parseAbsolute(a: Allocator, s: []const u8, d: *Diag) Error!Parsed {
    const p = try parse(a, s, d);
    if (p.bare and !std.mem.startsWith(u8, strAttr(&p.input, "path") orelse "", "/"))
        return d.fail(error.Flake, "flake reference '{s}' is not an absolute path", .{s});
    if (p.fragment.len > 0)
        return d.fail(error.Flake, "unexpected fragment '{s}' in flake reference '{s}'", .{ p.fragment, s });
    return p;
}

/// flakeref.cc:FlakeRef::to_string, also fetchers.cc:Input::to_string.
pub fn attrsToString(a: Allocator, m_in: *const Attrs, d: *Diag) Error![]const u8 {
    var m = try m_in.clone(a);
    const dir = m.remove("dir");
    var url = try toUrl(a, &m, d);
    if (dir) |v| if (v == .str and v.str.len > 0) try url.query.putFirst(a, "dir", v.str);
    return url.toString(a);
}

const testing = std.testing;

const T = struct {
    arena: std.heap.ArenaAllocator,
    d: Diag,

    fn init() T {
        return .{ .arena = .init(testing.allocator), .d = undefined };
    }
    fn a(t: *T) Allocator {
        return t.arena.allocator();
    }
    fn diag(t: *T) *Diag {
        t.d = .init(t.a());
        return &t.d;
    }
    fn shown(t: *T, s: []const u8) ![]const u8 {
        var p = try parseAbsolute(t.a(), s, t.diag());
        if (p.dir.len > 0) try p.input.put(t.a(), "dir", .{ .str = p.dir });
        return attrsToString(t.a(), &p.input, t.diag());
    }
    fn deinit(t: *T) void {
        t.arena.deinit();
    }
};

const rev_hex = "0123456789012345678901234567890123456789";

test "parses the kept schemes" {
    var t: T = .init();
    defer t.deinit();
    var p = try parseAbsolute(t.a(), "github:NixOS/nixpkgs/nixos-24.05?dir=lib", t.diag());
    try testing.expectEqualStrings("lib", p.dir);
    try testing.expectEqualStrings("nixos-24.05", strAttr(&p.input, "ref").?);
    p = try parseAbsolute(t.a(), "github:a/b/" ++ rev_hex, t.diag());
    try testing.expectEqualStrings(rev_hex, strAttr(&p.input, "rev").?);
    p = try parseAbsolute(t.a(), "github:a/b/x/y", t.diag());
    try testing.expectEqualStrings("x/y", strAttr(&p.input, "ref").?);
    p = try parseAbsolute(t.a(), "git+ssh://git@x.org:022/a.git?ref=main&shallow=1", t.diag());
    try testing.expectEqualStrings("ssh://git@x.org:22/a.git", strAttr(&p.input, "url").?);
    try testing.expect(p.input.get("shallow").?.eql(.{ .bool = true }));
    p = try parseAbsolute(t.a(), "https://x.org/a.tar.gz?narHash=x&lastModified=5&y=1", t.diag());
    try testing.expectEqualStrings("tarball", strAttr(&p.input, "type").?);
    try testing.expectEqualStrings("https://x.org/a.tar.gz?y=1", strAttr(&p.input, "url").?);
    try testing.expect(p.input.get("lastModified").?.eql(.{ .int = 5 }));
    p = try parseAbsolute(t.a(), "file+https://x.org/a", t.diag());
    try testing.expectEqualStrings("file", strAttr(&p.input, "type").?);
    p = try parseAbsolute(t.a(), "nixpkgs/release/" ++ rev_hex, t.diag());
    try testing.expectEqualStrings("nixpkgs", strAttr(&p.input, "id").?);
    try testing.expectEqualStrings("release", strAttr(&p.input, "ref").?);
    p = try parseAbsolute(t.a(), "//a//b/", t.diag());
    try testing.expectEqualStrings("/a/b/", strAttr(&p.input, "path").?);
    p = try parseAbsolute(t.a(), "path:/a%20b", t.diag());
    try testing.expectEqualStrings("/a b", strAttr(&p.input, "path").?);
    p = try parseAbsolute(t.a(), "path:", t.diag());
    try testing.expectEqualStrings("/", strAttr(&p.input, "path").?);
    p = try parse(t.a(), "./x?dir=d#a.b", t.diag());
    try testing.expect(p.bare);
    try testing.expectEqualStrings("./x", strAttr(&p.input, "path").?);
    try testing.expectEqualStrings("d", p.dir);
    try testing.expectEqualStrings("a.b", p.fragment);
    p = try parse(t.a(), "nixpkgs#hello", t.diag());
    try testing.expectEqualStrings("indirect", strAttr(&p.input, "type").?);
    try testing.expectEqualStrings("hello", p.fragment);
}

test "refuses a github ref named twice" {
    var t: T = .init();
    defer t.deinit();
    for ([_][]const u8{
        "github:a/b/c?ref=d",
        "gitlab:a/b/c?ref=d",
        "github:a/b/" ++ rev_hex ++ "?rev=" ++ rev_hex,
        "github:a/b?ref=d&rev=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "github:a/b/c?rev=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    }) |s| try testing.expectError(error.Flake, parseAbsolute(t.a(), s, t.diag()));
}

test "round trips" {
    var t: T = .init();
    defer t.deinit();
    const cases = [_][2][]const u8{
        .{ "github:NixOS/nixpkgs/23.05?dir=lib", "github:NixOS/nixpkgs/23.05?dir=lib" },
        .{ "github:a/b?rev=ABCDEF0123456789012345678901234567890123", "github:a/b/abcdef0123456789012345678901234567890123" },
        .{ "gitlab:a/b?host=x.org&ref=v1", "gitlab:a/b/v1?host=x.org" },
        .{ "nixpkgs/x", "flake:nixpkgs/x" },
        .{ "/a b/c?rev=x", "path:/a%20b/c?rev=x" },
        .{ "git+https://x.org/a?ref=main&foo=1&shallow=0", "git+https://x.org/a?foo=1&ref=main" },
        .{ "git://x.org/a", "git://x.org/a" },
        .{ "git+file:///tmp/x?dir=d", "git+file:///tmp/x?dir=d" },
        .{ "https://u:p@x.org:80/a%2f?b=c+d", "https://u:p@x.org:80/a%2F?b=c%2Bd" },
        .{ "tarball+http://x.org/a?b c=1", "http://x.org/a?b%20c=1" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try t.shown(c[0]));
}

test "git urls are fixed like nix" {
    var t: T = .init();
    defer t.deinit();
    const cases = [_][2][]const u8{
        .{ "/a b/c", "file:///a%20b/c" },
        .{ "rel/x", "file:rel/x" },
        .{ "file:///a/b", "file:///a/b" },
        .{ "git+file:///a/b", "file:///a/b" },
        .{ "git+https://x.org/a.git", "https://x.org/a.git" },
        .{ "ssh://git@x.org/a", "ssh://git@x.org/a" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try fixGitUrl(t.a(), c[0], t.diag()));
    try testing.expectError(error.Unsupported, fixGitUrl(t.a(), "git@github.com:a/b.git", t.diag()));
    try testing.expectError(error.Flake, fixGitUrl(t.a(), "x.org:a/b", t.diag()));
}

test "a file url is a local path" {
    var t: T = .init();
    defer t.deinit();
    try testing.expectEqualStrings("/a b/c", (try fileUrlPath(t.a(), "file:///a%20b/c")).?);
    try testing.expectEqualStrings("rel/x", (try fileUrlPath(t.a(), "file:rel/x")).?);
    try testing.expectEqual(null, try fileUrlPath(t.a(), "https://x.org/a"));
    // an authority is another machine's path, not this one's
    try testing.expectEqual(null, try fileUrlPath(t.a(), "file://host/a"));
}

fn attrsOf(a: Allocator, pairs: []const struct { []const u8, AttrVal }) !Attrs {
    var m: Attrs = .{};
    for (pairs) |p| try m.put(a, p[0], p[1]);
    return m;
}

test "to string from attrs" {
    var t: T = .init();
    defer t.deinit();
    const git = struct {
        fn f(tt: *T, url: []const u8) Error![]const u8 {
            const m = try attrsOf(tt.a(), &.{ .{ "type", .{ .str = "git" } }, .{ "url", .{ .str = url } } });
            return attrsToString(tt.a(), &m, tt.diag());
        }
    }.f;
    try testing.expectEqualStrings("git+file:///tmp/x", try git(&t, "file:///tmp/x"));
    try testing.expectEqualStrings("git+https://x.org/a", try git(&t, "git+https://x.org/a"));
    try testing.expectEqualStrings("git://x.org/a", try git(&t, "git://x.org/a"));
    try testing.expectError(error.Unsupported, git(&t, "/tmp/x"));
    try testing.expectError(error.Unsupported, git(&t, "git@github.com:a/b.git"));
    var m = try attrsOf(t.a(), &.{ .{ "type", .{ .str = "tarball" } }, .{ "url", .{ .str = "https://x.org/a" } }, .{ "narHash", .{ .str = "" } }, .{ "name", .{ .str = "n" } } });
    try testing.expectEqualStrings("https://x.org/a?narHash=sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D", try attrsToString(t.a(), &m, t.diag()));
    m = try attrsOf(t.a(), &.{ .{ "type", .{ .str = "path" } }, .{ "path", .{ .str = "rel/x" } } });
    try testing.expectEqualStrings("path:rel/x", try attrsToString(t.a(), &m, t.diag()));
}

test "bad and unsupported refs" {
    var t: T = .init();
    defer t.deinit();
    for ([_][]const u8{ "./foo", "github:a", "github:a/b#x", "nixpkgs/a/b/c", "/a#%zz" }) |s|
        try testing.expectError(error.Flake, parseAbsolute(t.a(), s, t.diag()));
    for ([_][]const u8{ "foo:bar", "sourcehut:~a/b", "hg+https://x.org/a", "https://[::1]/a", "https://x%41.org/a" }) |s|
        try testing.expectError(error.Unsupported, parseAbsolute(t.a(), s, t.diag()));
    var m = try attrsOf(t.a(), &.{.{ "type", .{ .str = "hg" } }});
    try testing.expectError(error.Unsupported, attrsToString(t.a(), &m, t.diag()));
    m = try attrsOf(t.a(), &.{ .{ "type", .{ .str = "github" } }, .{ "owner", .{ .str = "a" } } });
    try testing.expectError(error.Flake, attrsToString(t.a(), &m, t.diag()));
}
