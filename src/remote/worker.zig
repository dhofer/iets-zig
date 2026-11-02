//! The Nix worker protocol (libstore/worker-protocol.hh), spoken to a local
//! `nix-daemon` socket or to `nix-daemon --stdio` over ssh. One serial
//! connection; every op is one request and one `STDERR_*` reply loop.
//!
//! What an op returns lives in the `arena` the caller passes; the
//! connection's own state is in its `gpa`.

const std = @import("std");
const Io = std.Io;
const Reader = Io.Reader;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const Diag = @import("../diag.zig").Diag;
const remote = @import("../remote.zig");
const Error = remote.Error;
const Field = remote.Field;
const path_mod = @import("../store/path.zig");
const StorePath = path_mod.StorePath;
const event = @import("event.zig");
const Event = event.Event;
const Sink = event.Sink;
const grpc_config = @import("grpc/config.zig");
const PathInfo = @import("grpc/drvwire.zig").PathInfo;

pub const wire = @import("worker/wire.zig");

/// What `SetOptions` sends (remote-store.cc:setOptions). `default` is the
/// built-in set; `fromConfig` takes the values from the user's nix.conf
/// instead, and fails the way Nix does on a bad setting value.
pub const Options = struct {
    /// `0` would forbid local builds, so the default is the CPU count, what
    /// `max-jobs = auto` gives.
    max_jobs: u64,
    /// `0` means all cores.
    cores: u64 = 0,
    keep_going: bool = false,
    keep_failed: bool = false,
    substitutes: bool = true,
    /// `fallback`: build what a substituter fails to give.
    try_fallback: bool = false,
    /// `max-silent-time` in seconds; `0` is no limit.
    max_silent_time: u64 = 0,
    /// The override map: `Config::forwarded`.
    overrides: []const [2][]const u8 = &.{},

    pub fn default() Options {
        return .{ .max_jobs = std.Thread.getCpuCount() catch 1 };
    }

    /// The options the config forwards to the daemon; the overrides are in
    /// `arena`.
    pub fn fromConfig(arena: Allocator, c: *const config.Config, d: *Diag) !Options {
        const fwd = try c.forwarded(arena);
        const pairs = try arena.alloc([2][]const u8, fwd.len);
        for (fwd, pairs) |f, *p| p.* = .{ f.name, f.value };
        return .{
            .max_jobs = try c.maxJobs(d),
            .cores = try c.cores(d),
            .keep_going = try c.keepGoing(d),
            .keep_failed = try c.keepFailed(d),
            .substitutes = (try c.boolean("substitute", d)) orelse true,
            .try_fallback = (try c.boolean("fallback", d)) orelse false,
            .max_silent_time = (try c.int("max-silent-time", d)) orelse 0,
            .overrides = pairs,
        };
    }
};

const config = @import("../config.zig");

const worker_magic_1: u64 = 0x6e69_7863;
const worker_magic_2: u64 = 0x6478_696f;

const stderr_next: u64 = 0x6f6c_6d67;
const stderr_read: u64 = 0x6461_7461;
const stderr_write: u64 = 0x6461_7416;
const stderr_last: u64 = 0x616c_7473;
const stderr_error: u64 = 0x6378_7470;
const stderr_start_activity: u64 = 0x5354_5254;
const stderr_stop_activity: u64 = 0x5354_4f50;
const stderr_result: u64 = 0x5253_4c54;

/// The newest protocol this client speaks (worker-protocol.cc:WorkerProto::latest).
pub const latest_minor: u64 = 38;
/// Below this the handshake and `BuildPathsWithResults` differ; not worth supporting.
pub const min_minor: u64 = 35;

/// worker-protocol.hh:WorkerProto::Op, the subset used here.
const Op = enum(u64) {
    set_options = 19,
    query_path_info = 26,
    query_valid_paths = 31,
    add_indirect_root = 12,
    query_substitutable_path_infos = 30,
    nar_from_path = 38,
    query_missing = 40,
    query_derivation_output_map = 41,
    add_multiple_to_store = 44,
    build_paths_with_results = 46,
};

/// logging.hh:resPostBuildLogLine.
const res_post_build_log_line: u64 = 107;

/// error.hh:Verbosity.
const lvl_vomit: u64 = 7;

const default_socket_path = "/nix/var/nix/daemon-socket/socket";

/// The local daemon's socket, as uds-remote-store.cc:getDaemonSocketPath
/// picks it; allocated in `arena` when it comes from the environment.
pub fn defaultSocket(arena: Allocator, env: ?*const std.process.Environ.Map) Allocator.Error![]const u8 {
    const e = env orelse return default_socket_path;
    if (e.get("NIX_DAEMON_SOCKET_PATH")) |p| if (p.len > 0) return p;
    if (e.get("NIX_STATE_DIR")) |dir| if (dir.len > 0) return std.fs.path.join(arena, &.{ dir, "daemon-socket/socket" });
    return default_socket_path;
}

pub const Ssh = struct {
    user: ?[]const u8 = null,
    host: []const u8,
    port: ?u16 = null,
    /// The command run on the host: the URL's `remote-program` query
    /// parameter, `nix-daemon` by default, and then always `--stdio`
    /// (ssh-store.cc:openConnection).
    remote_program: []const []const u8,
    /// `ssh-key`: `-i`.
    key: ?[]const u8 = null,
    /// `compress`: `-C`.
    compress: bool = false,
    /// The ssh client run; not part of the URL. A test points it at a shim.
    command: []const u8 = "ssh",
};

/// Where the `--builder` or `--store` URL points. Strings live in the arena
/// `parse` was given.
pub const Transport = union(enum) {
    unix: []const u8,
    /// nix-grpc-store, which does not speak the worker protocol; see `grpc`.
    grpc: grpc_config.Config,
    ssh: Ssh,

    /// `daemon`, `unix://[/path]`, `ssh-ng://[user@]host[?remote-program=CMD]`,
    /// `grpc://host:port[?…]`. Null for every other scheme and for a
    /// malformed URL; `parseChecked` reports why.
    pub fn parse(arena: Allocator, url: []const u8, env: ?*const std.process.Environ.Map) ?Transport {
        var d: Diag = .init(arena);
        defer d.deinit();
        return parseChecked(arena, url, default_system, env, &d) catch null;
    }

    /// `parse` with the errors kept, and the `system=` default the caller's
    /// `system` setting implies.
    pub fn parseChecked(arena: Allocator, url: []const u8, system: []const u8, env: ?*const std.process.Environ.Map, d: *Diag) Error!?Transport {
        if (try grpc_config.Config.parse(arena, url, system, d)) |cfg| return .{ .grpc = cfg };
        return parseWorker(arena, url, env, d);
    }

    /// The store as Nix's getHumanReadableURI names it, for the log.
    pub fn uri(t: *const Transport, w: *Writer, env: ?*const std.process.Environ.Map) Writer.Error!void {
        switch (t.*) {
            .unix => |p| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                var fba: std.heap.FixedBufferAllocator = .init(&buf);
                const def = defaultSocket(fba.allocator(), env) catch default_socket_path;
                if (std.mem.eql(u8, p, def)) return w.writeAll("daemon");
                try w.print("unix://{s}", .{p});
            },
            .grpc => |*c| try c.url(w),
            .ssh => |s| if (s.user) |u| try w.print("ssh-ng://{s}@{s}", .{ u, s.host }) else try w.print("ssh-ng://{s}", .{s.host}),
        }
    }

    fn parseWorker(arena: Allocator, url: []const u8, env: ?*const std.process.Environ.Map, d: *Diag) Error!?Transport {
        // `auto` is nix.conf's default `store`, which iets answers with the
        // daemon: it has no local store of its own (docs/reference/settings.md).
        const eql = std.mem.eql;
        if (eql(u8, url, "daemon") or eql(u8, url, "unix://") or eql(u8, url, "auto") or url.len == 0)
            return .{ .unix = try defaultSocket(arena, env) };
        if (std.mem.startsWith(u8, url, "unix://")) return .{ .unix = try arena.dupe(u8, url["unix://".len..]) };
        if (!std.mem.startsWith(u8, url, "ssh-ng://")) return null;
        var rest = url["ssh-ng://".len..];
        var query: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '?')) |i| {
            query = rest[i + 1 ..];
            rest = rest[0..i];
        }
        const auth = try authority(arena, std.mem.trimEnd(u8, rest, "/"), d);
        var program: std.ArrayList([]const u8) = .empty;
        try program.append(arena, "nix-daemon");
        var key: ?[]const u8 = null;
        var compress = false;
        var it = std.mem.splitScalar(u8, query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const k = kv[0..eq];
            const v = try percentDecode(arena, kv[eq + 1 ..]);
            if (eql(u8, k, "remote-program")) {
                program.clearRetainingCapacity();
                var words = std.mem.tokenizeAny(u8, v, " \t\n\r\x0b\x0c");
                while (words.next()) |word| try program.append(arena, word);
            } else if (eql(u8, k, "ssh-key")) {
                key = v;
            } else if (eql(u8, k, "compress")) {
                compress = !eql(u8, v, "false") and !eql(u8, v, "0");
            }
        }
        // ssh-store.cc:openConnection appends it to whatever remote-program
        // names, so a remote program can never drop the protocol.
        try program.append(arena, "--stdio");
        return .{ .ssh = .{
            .user = auth.user,
            .host = auth.host,
            .port = auth.port,
            .remote_program = program.items,
            .key = key,
            .compress = compress,
        } };
    }
};

/// The `system` setting's default.
pub const default_system = config.default_system;

const Authority = struct { user: ?[]const u8, host: []const u8, port: ?u16 };

/// `[user@]host[:port]`, with an IPv6 host in brackets. ssh.cc:checkValidAuthority
/// refuses a name that ssh would read as an option.
fn authority(arena: Allocator, rest: []const u8, d: *Diag) Error!Authority {
    const bad = "invalid SSH authority: '{s}': ";
    var user: ?[]const u8 = null;
    var hostport = rest;
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |i| {
        user = try arena.dupe(u8, rest[0..i]);
        hostport = rest[i + 1 ..];
    }
    var host = hostport;
    var port_s: ?[]const u8 = null;
    if (std.mem.startsWith(u8, hostport, "[")) {
        const r = hostport[1..];
        const close = std.mem.indexOfScalar(u8, r, ']') orelse
            return d.fail(error.Usage, bad ++ "unterminated '['", .{rest});
        host = r[0..close];
        const tail = r[close + 1 ..];
        if (std.mem.startsWith(u8, tail, ":")) port_s = tail[1..];
    } else if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |i| {
        host = hostport[0..i];
        port_s = hostport[i + 1 ..];
    }
    const port: ?u16 = if (port_s) |p| std.fmt.parseInt(u16, p, 10) catch
        return d.fail(error.Usage, bad ++ "'{s}' is not a port", .{ rest, p }) else null;
    if (user) |u| {
        if (u.len == 0) return d.fail(error.Usage, bad ++ "user name must not be empty", .{rest});
        if (u[0] == '-') return d.fail(error.Usage, bad ++ "user name '{s}' must not start with '-'", .{ rest, u });
    }
    if (host.len == 0) return d.fail(error.Usage, bad ++ "host name must not be empty", .{rest});
    if (host[0] == '-') return d.fail(error.Usage, bad ++ "host name '{s}' must not start with '-'", .{ rest, host });
    return .{ .user = user, .host = try arena.dupe(u8, host), .port = port };
}

/// Everything before the remote command, in the order of ssh.cc:startCommand
/// and addCommonSSHOpts. The host comes first, so no option of `NIX_SSHOPTS`
/// can turn it into one; the caller adds `--` before the command.
fn sshArgs(arena: Allocator, s: Ssh, env: ?*const std.process.Environ.Map, d: *Diag) Error![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(arena, if (s.user) |u| try std.fmt.allocPrint(arena, "{s}@{s}", .{ u, s.host }) else s.host);
    try args.append(arena, "-x");
    // the same knob Nix's ssh.cc reads, so ControlMaster and friends can be
    // set per run
    if (env) |e| if (e.get("NIX_SSHOPTS")) |opts| try args.appendSlice(arena, try shellSplit(arena, opts, d));
    if (s.key) |k| try args.appendSlice(arena, &.{ "-i", k });
    if (s.compress) try args.append(arena, "-C");
    if (s.port) |p| try args.append(arena, try std.fmt.allocPrint(arena, "-p{d}", .{p}));
    return args.items;
}

/// strings.cc:shellSplitString, what `NIX_SSHOPTS` is split with.
pub fn shellSplit(arena: Allocator, s: []const u8, d: *Diag) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var started = false;
    var quote: ?u8 = null;
    var escaping = false;
    for (s) |c| {
        if (quote) |q| {
            started = true;
            if (q == '\'') {
                if (c == '\'') quote = null else try cur.append(arena, c);
            } else if (escaping) {
                if (c != '$' and c != '`' and c != '"' and c != '\\') try cur.append(arena, '\\');
                try cur.append(arena, c);
                escaping = false;
            } else if (c == '\\') {
                escaping = true;
            } else if (c == '"') {
                quote = null;
            } else try cur.append(arena, c);
        } else if (escaping) {
            try cur.append(arena, c);
            started = true;
            escaping = false;
        } else switch (c) {
            '\\' => escaping = true,
            ' ', '\t' => if (started) {
                try out.append(arena, try cur.toOwnedSlice(arena));
                started = false;
            },
            '"', '\'' => {
                quote = c;
                started = true;
            },
            else => {
                try cur.append(arena, c);
                started = true;
            },
        }
    }
    if (quote) |q| return if (q == '\'') d.fail(error.Usage, "unterminated single quote", .{}) else d.fail(error.Usage, "unterminated double quote", .{});
    if (started) try out.append(arena, cur.items);
    return out.items;
}

/// `%XX` and `+` in a URL query value.
pub fn percentDecode(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const raw = try @import("../bytes.zig").percentDecode(arena, s, true);
    return @import("../syntax/text.zig").lossyAlloc(arena, raw);
}

/// Round trips and bytes on one connection, for `--timings`.
pub const Stats = struct {
    /// Worker ops sent, `SetOptions` included.
    ops: usize = 0,
    /// Ops plus the handshake exchanges that each wait for the daemon.
    round_trips: usize = 0,
    bytes_sent: u64 = 0,
};

/// What building some paths takes (remote-store.cc:queryMissing).
pub const Missing = struct {
    will_build: []const []const u8,
    will_substitute: []const []const u8,
    unknown: []const []const u8,
    download_size: u64,
    nar_size: u64,
};

/// worker-protocol.cc:BuildResult, the fields this client reads.
pub const BuildResult = struct {
    path: []const u8,
    status: u64,
    msg: []const u8,

    /// common-protocol.cc:buildResultStatusTable: Built, Substituted,
    /// AlreadyValid, ResolvesToAlreadyValid.
    pub fn success(r: BuildResult) bool {
        return switch (r.status) {
            0, 1, 2, 13 => true,
            else => false,
        };
    }
};

/// The daemon bumps `done` or `failed` on its builds activity just before a
/// build's own activity stops, and its worker finishes one goal at a time.
/// So the oldest unclaimed change belongs to the next build that stops.
const BuildCounts = struct {
    act: ?u64 = null,
    done: u64 = 0,
    failed: u64 = 0,
    /// One entry per change: true for a success; `head` is the oldest.
    pending: std.ArrayList(bool) = .empty,
    head: usize = 0,

    fn progress(c: *BuildCounts, gpa: Allocator, fields: []const Field) Allocator.Error!void {
        const n = struct {
            fn f(fs: []const Field, i: usize) u64 {
                if (i >= fs.len) return 0;
                return switch (fs[i]) {
                    .int => |v| v,
                    .string => 0,
                };
            }
        }.f;
        const done = n(fields, 0);
        const failed = n(fields, 3);
        var i = c.done;
        while (i < done) : (i += 1) try c.pending.append(gpa, true);
        i = c.failed;
        while (i < failed) : (i += 1) try c.pending.append(gpa, false);
        c.done = done;
        c.failed = failed;
    }

    fn reset(c: *BuildCounts, act: ?u64) void {
        c.act = act;
        c.done = 0;
        c.failed = 0;
        c.clearPending();
    }

    fn clearPending(c: *BuildCounts) void {
        c.pending.clearRetainingCapacity();
        c.head = 0;
    }

    fn popFront(c: *BuildCounts) ?bool {
        if (c.head >= c.pending.items.len) return null;
        const v = c.pending.items[c.head];
        c.head += 1;
        if (c.head == c.pending.items.len) c.clearPending();
        return v;
    }

    fn pendingSlice(c: *const BuildCounts) []const bool {
        return c.pending.items[c.head..];
    }
};

/// The stream under a connection: a socket or an ssh child's pipes.
const Stream = union(enum) {
    unix: struct { stream: Io.net.Stream, r: Io.net.Stream.Reader, w: Io.net.Stream.Writer },
    ssh: struct { child: std.process.Child, r: Io.File.Reader, w: Io.File.Writer },
};

/// What writing an `Upload`'s body fails with.
pub const BodyError = wire.ObjectError || Error;

/// An `AddMultipleToStore` under way: the caller writes the body into
/// `writer()`, the count, then each `ValidPathInfo` followed by its NAR
/// (store-api.cc:Store::addMultipleToStore(Source &)), and ends with `finish`.
pub const Upload = struct {
    c: *Connection,
    sink: wire.FramedSink,

    pub fn writer(u: *Upload) *Writer {
        return &u.sink.interface;
    }

    /// A body that failed: a write the connection refused, or a failure the
    /// body reported in `d`, under the context "daemon connection".
    pub fn fail(u: *Upload, e: BodyError, d: *Diag) Error {
        if (e == error.WriteFailed) return u.c.writeFail(d);
        if (d.msg == null) return remote.failIo(d, e, "daemon connection", .{});
        remote.prefix(d, "daemon connection", .{});
        return error.Io;
    }

    /// Sends the last frame and the terminator, then waits for the daemon.
    pub fn finish(u: *Upload, on_event: Sink, d: *Diag) Error!void {
        u.sink.finish() catch return u.c.writeFail(d);
        try u.c.processStderr(on_event, d);
    }
};

pub const Connection = struct {
    gpa: Allocator,
    io: Io,
    log: remote.Log,
    stream: Stream,
    /// The bytes out, counted on their way into the stream.
    to: wire.Counting,
    from: *Reader,
    minor: u64 = 0,
    daemon_nix_version: []const u8 = "",
    /// True when the daemon trusts us (protocol >= 1.35).
    trusted: ?bool = null,
    stats: Stats = .{},
    /// Running builds by activity id, to attribute log lines.
    activities: std.AutoArrayHashMapUnmanaged(u64, []const u8) = .empty,
    /// Follows a nested activity back to the build it belongs to.
    parents: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    /// The daemon's activity ids to the ones this process logs them under.
    ids: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    builds: BuildCounts = .{},
    /// What one message of the stderr stream needs; reset per message.
    scratch: std.heap.ArenaAllocator,
    in_buf: []u8,
    out_buf: []u8,
    /// `AddMultipleToStore`'s frame, allocated by the first.
    frame: []u8 = &.{},

    const buf_len = 1 << 20;

    pub fn open(gpa: Allocator, io: Io, transport: *const Transport, env: ?*const std.process.Environ.Map, log: remote.Log, on_event: Sink, d: *Diag) Error!*Connection {
        return openWith(gpa, io, transport, .default(), env, log, on_event, d);
    }

    /// Opens the transport and runs the handshake and `SetOptions`, as
    /// remote-store.cc:initConnection does.
    pub fn openWith(gpa: Allocator, io: Io, transport: *const Transport, options: Options, env: ?*const std.process.Environ.Map, log: remote.Log, on_event: Sink, d: *Diag) Error!*Connection {
        // `close` frees all three once the stream is open
        var closes = false;
        const c = try gpa.create(Connection);
        errdefer if (!closes) gpa.destroy(c);
        const in_buf = try gpa.alloc(u8, buf_len);
        errdefer if (!closes) gpa.free(in_buf);
        const out_buf = try gpa.alloc(u8, buf_len);
        errdefer if (!closes) gpa.free(out_buf);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .log = log,
            .stream = undefined,
            .to = undefined,
            .from = undefined,
            .scratch = .init(gpa),
            .in_buf = in_buf,
            .out_buf = out_buf,
        };
        switch (transport.*) {
            .grpc => |*cfg| return d.fail(error.Usage, "'{f}' is a gRPC store, not a worker-protocol daemon", .{cfg}),
            .unix => |path| {
                const addr = Io.net.UnixAddress.init(path) catch |e| return remote.failIo(d, e, "cannot connect to '{s}'", .{path});
                const s = addr.connect(io) catch |e| return remote.failIo(d, e, "cannot connect to '{s}'", .{path});
                c.stream = .{ .unix = .{ .stream = s, .r = s.reader(io, in_buf), .w = s.writer(io, &.{}) } };
                c.from = &c.stream.unix.r.interface;
                c.to = .init(&c.stream.unix.w.interface, out_buf);
            },
            .ssh => |s| {
                var arena: std.heap.ArenaAllocator = .init(gpa);
                defer arena.deinit();
                const a = arena.allocator();
                var argv: std.ArrayList([]const u8) = .empty;
                try argv.append(a, s.command);
                try argv.appendSlice(a, try sshArgs(a, s, env, d));
                try argv.append(a, "--");
                try argv.appendSlice(a, s.remote_program);
                const child = std.process.spawn(io, .{
                    .argv = argv.items,
                    .stdin = .pipe,
                    .stdout = .pipe,
                    .stderr = .inherit,
                }) catch |e| return remote.failIo(d, e, "cannot run ssh", .{});
                c.stream = .{ .ssh = .{ .child = child, .r = undefined, .w = undefined } };
                const ss = &c.stream.ssh;
                ss.r = ss.child.stdout.?.readerStreaming(io, in_buf);
                ss.w = ss.child.stdin.?.writerStreaming(io, &.{});
                c.from = &ss.r.interface;
                c.to = .init(&ss.w.interface, out_buf);
            },
        }
        closes = true;
        errdefer c.close();
        try c.handshake(d);
        try c.processStderr(on_event, d);
        // ssh-store.cc:setOptions sends nothing, and nixbuild.net rejects the op.
        if (transport.* != .ssh) try c.setOptions(options, on_event, d);
        return c;
    }

    /// A local ssh child exits on EOF of its stdin, so that is closed before
    /// the wait. nixbuild.net keeps the session open for minutes after EOF,
    /// so the child is killed too, as Nix's `Pid::~Pid` does.
    pub fn close(c: *Connection) void {
        // a daemon that went away mid-op never stopped these
        var it = c.ids.valueIterator();
        while (it.next()) |id| c.log.stop(id.*);
        c.to.interface.flush() catch {};
        switch (c.stream) {
            .unix => |*u| u.stream.close(c.io),
            .ssh => |*s| {
                if (s.child.stdin) |f| f.close(c.io);
                s.child.stdin = null;
                s.child.kill(c.io);
            },
        }
        for (c.activities.values()) |v| c.gpa.free(v);
        c.activities.deinit(c.gpa);
        c.parents.deinit(c.gpa);
        c.ids.deinit(c.gpa);
        c.builds.pending.deinit(c.gpa);
        c.scratch.deinit();
        if (c.daemon_nix_version.len > 0) c.gpa.free(c.daemon_nix_version);
        c.gpa.free(c.in_buf);
        c.gpa.free(c.out_buf);
        c.gpa.free(c.frame);
        c.gpa.destroy(c);
    }

    pub fn bytesSent(c: *const Connection) u64 {
        return c.to.count();
    }

    fn syncStats(c: *Connection) void {
        c.stats.bytes_sent = c.bytesSent();
    }

    /// The OS's error behind a failed read or write of the stream.
    fn streamErr(c: *Connection, read: bool) ?anyerror {
        return switch (c.stream) {
            .unix => |*u| if (read) u.r.err else u.w.err,
            .ssh => |*s| if (read) s.r.err else s.w.err,
        };
    }

    /// Every failure of the connection's own reads reports the same way:
    /// `Error::io("daemon connection", e)`.
    fn readFail(c: *Connection, d: *Diag) Error {
        if (d.msg) |m| if (std.mem.eql(u8, m, "read failed")) if (c.streamErr(true)) |e| {
            return remote.failIo(d, e, "daemon connection", .{});
        };
        remote.prefix(d, "daemon connection", .{});
        return error.Io;
    }

    fn writeFail(c: *Connection, d: *Diag) Error {
        return remote.failIo(d, c.streamErr(false) orelse error.BrokenPipe, "daemon connection", .{});
    }

    fn w(c: *Connection) *Writer {
        return &c.to.interface;
    }

    fn writeU64(c: *Connection, n: u64, d: *Diag) Error!void {
        wire.writeU64(c.w(), n) catch return c.writeFail(d);
    }

    fn writeStr(c: *Connection, s: []const u8, d: *Diag) Error!void {
        wire.writeStr(c.w(), s) catch return c.writeFail(d);
    }

    fn writeStrs(c: *Connection, items: []const []const u8, d: *Diag) Error!void {
        wire.writeStrs(c.w(), items) catch return c.writeFail(d);
    }

    fn flush(c: *Connection, d: *Diag) Error!void {
        c.w().flush() catch return c.writeFail(d);
    }

    fn readU64(c: *Connection, d: *Diag) Error!u64 {
        return wire.readU64(c.from, d) catch |e| switch (e) {
            error.Io => c.readFail(d),
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn readStr(c: *Connection, arena: Allocator, d: *Diag) Error![]const u8 {
        return wire.readStr(c.from, arena, d) catch |e| switch (e) {
            error.Io => c.readFail(d),
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn readStrs(c: *Connection, arena: Allocator, d: *Diag) Error![][]const u8 {
        return wire.readStrs(c.from, arena, d) catch |e| switch (e) {
            error.Io => c.readFail(d),
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    fn readPaths(c: *Connection, arena: Allocator, d: *Diag) Error![][]const u8 {
        return wire.readPaths(c.from, arena, d) catch |e| switch (e) {
            error.Io => c.readFail(d),
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// A wire reader's result, its failure reported as the connection's.
    fn conn(c: *Connection, r: anytype, d: *Diag) Error!@typeInfo(@TypeOf(r)).error_union.payload {
        return r catch |e| switch (e) {
            error.Io => c.readFail(d),
            error.OutOfMemory => error.OutOfMemory,
        };
    }

    /// worker-protocol-connection.cc:BasicClientConnection::handshake and postHandshake.
    fn handshake(c: *Connection, d: *Diag) Error!void {
        try c.writeU64(worker_magic_1, d);
        try c.writeU64((1 << 8) | latest_minor, d);
        try c.flush(d);
        if (try c.readU64(d) != worker_magic_2) return d.fail(error.Protocol, "nix-daemon protocol mismatch", .{});
        const daemon = try c.readU64(d);
        if ((daemon & 0xff00) >> 8 != 1) return d.fail(error.Protocol, "Nix daemon protocol version not supported", .{});
        c.minor = @min(daemon & 0xff, latest_minor);
        c.stats.round_trips += 1;
        if (c.minor < min_minor)
            return d.fail(error.Protocol, "the Nix daemon speaks protocol 1.{d}; this client needs 1.{d} or newer", .{ c.minor, min_minor });
        _ = c.scratch.reset(.retain_capacity);
        if (c.minor >= 38) {
            try c.writeStrs(&.{}, d);
            try c.flush(d);
            _ = try c.readStrs(c.scratch.allocator(), d);
            c.stats.round_trips += 1;
        }
        try c.writeU64(0, d);
        try c.writeU64(0, d);
        try c.flush(d);
        c.daemon_nix_version = try c.readStr(c.gpa, d);
        // worker-protocol.cc:Serialise<std::optional<TrustedFlag>>
        c.trusted = switch (try c.readU64(d)) {
            0 => null,
            1 => true,
            2 => false,
            else => |n| return d.fail(error.Protocol, "invalid trusted status {d} from the Nix daemon", .{n}),
        };
        c.stats.round_trips += 1;
    }

    fn op(c: *Connection, o: Op, d: *Diag) Error!void {
        c.stats.ops += 1;
        c.stats.round_trips += 1;
        try c.writeU64(@backingInt(o), d);
    }

    /// remote-store.cc:setOptions: the same twelve fields, then the override map.
    fn setOptions(c: *Connection, o: Options, on_event: Sink, d: *Diag) Error!void {
        try c.op(.set_options, d);
        for ([_]u64{
            @intFromBool(o.keep_failed), // keep-failed
            @intFromBool(o.keep_going), // keep-going
            @intFromBool(o.try_fallback), // try-fallback
            remote.lvl_info, // verbosity
            o.max_jobs, // max-jobs
            o.max_silent_time, // max-silent-time
            1, // obsolete use-build-hook
            lvl_vomit, // build verbosity: lvlVomit means verboseBuild = false
            0, // obsolete log type
            0, // obsolete print build trace
            o.cores, // cores
            @intFromBool(o.substitutes), // substitute
        }) |v| try c.writeU64(v, d);
        try c.writeU64(o.overrides.len, d);
        for (o.overrides) |kv| {
            try c.writeStr(kv[0], d);
            try c.writeStr(kv[1], d);
        }
        try c.processStderr(on_event, d);
    }

    /// worker-protocol-connection.cc:processStderrReturn: drains the
    /// daemon's log stream until `STDERR_LAST` (the reply follows) or
    /// `STDERR_ERROR`.
    fn processStderr(c: *Connection, on_event: Sink, d: *Diag) Error!void {
        try c.flush(d);
        while (true) {
            _ = c.scratch.reset(.retain_capacity);
            const a = c.scratch.allocator();
            switch (try c.readU64(d)) {
                stderr_last => {
                    c.syncStats();
                    return;
                },
                stderr_next => {
                    var line: []const u8 = try c.conn(wire.peekBytes(c.from, a, wire.max_string, d), d);
                    while (line.len > 0 and line[line.len - 1] == '\n') line.len -= 1;
                    on_event.send(.{ .log = .{ .drv_path = "", .line = line } });
                },
                stderr_start_activity => try c.startActivity(a, on_event, d),
                stderr_stop_activity => {
                    const act = try c.readU64(d);
                    if (c.ids.fetchRemove(act)) |kv| c.log.stop(kv.value);
                    _ = c.parents.remove(act);
                    if (c.activities.fetchSwapRemove(act)) |kv| {
                        defer c.gpa.free(kv.value);
                        // a build hook runs two activities for one build and
                        // the verdict belongs to the last
                        const last = for (c.activities.values()) |v| {
                            if (std.mem.eql(u8, v, kv.value)) break false;
                        } else true;
                        const built = last and (c.builds.popFront() orelse false);
                        on_event.send(.{ .stopped = .{ .drv_path = kv.value, .built = built } });
                    }
                },
                stderr_result => {
                    const act = try c.readU64(d);
                    const ty = try c.readU64(d);
                    const fields = try c.readFields(a, d);
                    if (c.ids.get(act)) |id| c.log.result(id, ty, fields);
                    if (ty == remote.res_progress and c.builds.act == act) try c.builds.progress(c.gpa, fields);
                    if ((ty == remote.res_build_log_line or ty == res_post_build_log_line) and fields.len > 0 and fields[0] == .string)
                        on_event.send(.{ .log = .{ .drv_path = c.buildOf(act) orelse "", .line = fields[0].string } });
                    if (ty == remote.res_set_phase and fields.len > 0 and fields[0] == .string) if (c.buildOf(act)) |drv|
                        on_event.send(.{ .phase = .{ .drv_path = drv, .phase = fields[0].string } });
                },
                stderr_error => {
                    const e = c.readError(a, d);
                    c.syncStats();
                    return e;
                },
                stderr_read, stderr_write => return d.fail(error.Protocol, "daemon asked for a data stream this client does not provide", .{}),
                else => |other| return d.fail(error.Protocol, "got unknown message type 0x{x} from Nix daemon", .{other}),
            }
        }
    }

    fn startActivity(c: *Connection, a: Allocator, on_event: Sink, d: *Diag) Error!void {
        const act = try c.readU64(d);
        const lvl = try c.readU64(d);
        const ty = try c.readU64(d);
        const s = try c.readStr(a, d);
        const fields = try c.readFields(a, d);
        const parent = try c.readU64(d);
        // worker-protocol-connection.cc:processStderr hands these to the
        // client's logger; fresh ids keep two connections apart
        if (c.log.activities()) {
            const id = c.log.activityId();
            try c.ids.put(c.gpa, act, id);
            const up = c.ids.get(parent) orelse 0;
            c.log.start(id, lvl, ty, s, fields, up);
        }
        if (ty == remote.act_builds) c.builds.reset(act);
        if (ty == remote.act_build and fields.len > 0 and fields[0] == .string) {
            // a goal that failed without a build activity left a change
            // nobody will claim
            c.builds.clearPending();
            const drv = try c.gpa.dupe(u8, fields[0].string);
            const gop = try c.activities.getOrPut(c.gpa, act);
            if (gop.found_existing) c.gpa.free(gop.value_ptr.*);
            gop.value_ptr.* = drv;
            on_event.send(.{ .started = .{ .drv_path = drv } });
        } else if (parent != 0) {
            // A build's log can arrive under a nested activity (a remote
            // builder, a substitution): remember the chain so the line still
            // names its derivation.
            try c.parents.put(c.gpa, act, parent);
        }
    }

    /// The derivation whose build `act` belongs to, following the
    /// activity's parents: a remote builder's log arrives under a child
    /// activity.
    fn buildOf(c: *const Connection, act: u64) ?[]const u8 {
        var id = act;
        for (0..16) |_| {
            if (c.activities.get(id)) |drv| return drv;
            id = c.parents.get(id) orelse return null;
        }
        return null;
    }

    /// worker-protocol-connection.cc:readFields.
    fn readFields(c: *Connection, a: Allocator, d: *Diag) Error![]Field {
        const n = try c.readU64(d);
        var fields: std.ArrayList(Field) = try .initCapacity(a, @min(n, 16));
        for (0..n) |_| {
            const f: Field = switch (try c.readU64(d)) {
                0 => .{ .int = try c.readU64(d) },
                1 => .{ .string = try c.readStr(a, d) },
                else => |t| return d.fail(error.Protocol, "got unsupported field type 0x{x} from Nix daemon", .{t}),
            };
            try fields.append(a, f);
        }
        return fields.items;
    }

    /// serialise.cc:readError (protocol >= 1.26).
    fn readError(c: *Connection, a: Allocator, d: *Diag) Error {
        const ty = c.readStr(a, d) catch |e| return e;
        if (!std.mem.eql(u8, ty, "Error")) return d.fail(error.Protocol, "unexpected error type '{s}'", .{ty});
        _ = c.readU64(d) catch |e| return e; // level
        _ = c.readStr(a, d) catch |e| return e; // name
        var msg: std.ArrayList(u8) = .empty;
        msg.appendSlice(a, c.readStr(a, d) catch |e| return e) catch return error.OutOfMemory;
        _ = c.readU64(d) catch |e| return e; // have pos
        const traces = c.readU64(d) catch |e| return e;
        for (0..traces) |_| {
            _ = c.readU64(d) catch |e| return e; // have pos
            const hint = c.readStr(a, d) catch |e| return e;
            msg.appendSlice(a, "\n       … ") catch return error.OutOfMemory;
            msg.appendSlice(a, hint) catch return error.OutOfMemory;
        }
        return d.fail(error.Protocol, "{s}", .{msg.items});
    }

    /// `QueryValidPaths` with substitution off; returns the valid subset.
    pub fn queryValid(c: *Connection, arena: Allocator, paths: []const StorePath, on_event: Sink, d: *Diag) Error![]StorePath {
        return c.validPaths(arena, paths, false, on_event, d);
    }

    /// `QueryValidPaths` with the substitute flag set (protocol >= 1.27),
    /// which runs `Store::substitutePaths` on the daemon before it answers
    /// (daemon.cc:performOp): the valid subset is what the substituters gave
    /// us. Nothing is evaluated and no derivation is built.
    pub fn substitutePaths(c: *Connection, arena: Allocator, paths: []const StorePath, on_event: Sink, d: *Diag) Error![]StorePath {
        return c.validPaths(arena, paths, true, on_event, d);
    }

    fn validPaths(c: *Connection, arena: Allocator, paths: []const StorePath, substitute: bool, on_event: Sink, d: *Diag) Error![]StorePath {
        try c.op(.query_valid_paths, d);
        wire.writePaths(c.w(), paths) catch return c.writeFail(d);
        try c.writeU64(@intFromBool(substitute), d);
        try c.processStderr(on_event, d);
        return c.conn(wire.readStorePaths(c.from, arena, d), d);
    }

    /// `QueryPathInfo`: the path's `UnkeyedValidPathInfo`, null when the
    /// store has not got it (remote-store.cc:queryPathInfoUncached).
    pub fn queryPathInfo(c: *Connection, arena: Allocator, path: []const u8, on_event: Sink, d: *Diag) Error!?PathInfo {
        try c.op(.query_path_info, d);
        try c.writeStr(path, d);
        c.processStderr(on_event, d) catch |e| {
            // worker-protocol-connection.cc:queryPathInfo: an old daemon says
            // so with an error, and Nix's client still reads it that way
            if (e == error.Protocol and std.mem.indexOf(u8, d.message(), "is not valid") != null) return null;
            return e;
        };
        if (!try c.conn(wire.readBool(c.from, d), d)) return null;
        return PathInfo.read(arena, path, c.from, d) catch |e| switch (e) {
            error.Io => c.readFail(d),
            else => e,
        };
    }

    /// `AddMultipleToStore`, begun: the op goes out and the body into the
    /// returned `Upload`'s framed stream, so the daemon can find its end
    /// without parsing it. `dont_check_sigs` asks the daemon to skip the
    /// signature check, which it grants a trusted client only
    /// (daemon.cc:performOp).
    pub fn addMultipleToStore(c: *Connection, dont_check_sigs: bool, d: *Diag) Error!Upload {
        try c.op(.add_multiple_to_store, d);
        try c.writeU64(0, d);
        try c.writeU64(@intFromBool(dont_check_sigs), d);
        try c.flush(d);
        if (c.frame.len == 0) c.frame = try c.gpa.alloc(u8, wire.FramedSink.frame);
        return .{ .c = c, .sink = .init(c.w(), c.frame) };
    }

    /// `BuildPathsWithResults` in normal mode; `paths` are legacy derived
    /// paths (`/nix/store/x.drv!out1,out2` or `!*`), the encoding for
    /// protocol >= 1.30.
    pub fn buildPathsWithResults(c: *Connection, arena: Allocator, paths: []const []const u8, on_event: Sink, d: *Diag) Error![]BuildResult {
        try c.op(.build_paths_with_results, d);
        try c.writeStrs(paths, d);
        try c.writeU64(0, d);
        try c.processStderr(on_event, d);
        const n = try c.readU64(d);
        var results: std.ArrayList(BuildResult) = .empty;
        for (0..n) |_| try results.append(arena, try c.readBuildResult(arena, d));
        return results.items;
    }

    /// worker-protocol.cc:Serialise<KeyedBuildResult> (protocol >= 1.29),
    /// the checks of Nix's client included.
    fn readBuildResult(c: *Connection, arena: Allocator, d: *Diag) Error!BuildResult {
        const r = c.from;
        const path = try c.conn(wire.derivedPath(arena, try c.readStr(arena, d), d), d);
        // common-protocol.cc:buildResultStatusTable
        const status = try c.conn(wire.readNum(r, std.math.maxInt(u8), d), d);
        if (status > 14) return d.fail(error.Protocol, "invalid BuildResult status {d} from the Nix daemon", .{status});
        const msg = try c.readStr(arena, d);
        _ = try c.conn(wire.readNum(r, std.math.maxInt(u32), d), d); // times built
        _ = try c.conn(wire.readBool(r, d), d); // non-deterministic
        _ = try c.conn(wire.readTime(r, d), d); // start
        _ = try c.conn(wire.readTime(r, d), d); // stop
        if (c.minor >= 37) {
            // CPU time of user and system: an optional microseconds
            for (0..2) |_| switch (try c.conn(wire.readNum(r, std.math.maxInt(u8), d), d)) {
                0 => {},
                1 => _ = try c.conn(wire.readNum(r, std.math.maxInt(i64), d), d),
                else => return d.fail(error.Protocol, "invalid optional tag from the Nix daemon", .{}),
            };
        }
        const outputs = try c.readU64(d);
        for (0..outputs) |_| {
            _ = c.scratch.reset(.retain_capacity);
            const a = c.scratch.allocator();
            try c.conn(wire.drvOutput(try c.readStr(a, d), d), d);
            try c.conn(wire.realisation(c.gpa, try c.conn(wire.readBytes(r, a, wire.max_string, d), d), d), d);
        }
        return .{ .path = path, .status = status, .msg = msg };
    }

    /// `QueryMissing`; `paths` are derived paths, as for `BuildPathsWithResults`.
    pub fn queryMissing(c: *Connection, arena: Allocator, paths: []const []const u8, on_event: Sink, d: *Diag) Error!Missing {
        try c.op(.query_missing, d);
        try c.writeStrs(paths, d);
        try c.processStderr(on_event, d);
        return .{
            .will_build = try c.readPaths(arena, d),
            .will_substitute = try c.readPaths(arena, d),
            .unknown = try c.readPaths(arena, d),
            .download_size = try c.readU64(d),
            .nar_size = try c.readU64(d),
        };
    }

    pub const OutputEntry = struct { name: []const u8, path: ?[]const u8 };

    /// `QueryDerivationOutputMap`: output name to store path when the daemon
    /// knows it, sorted by name.
    pub fn queryDerivationOutputMap(c: *Connection, arena: Allocator, drv: []const u8, on_event: Sink, d: *Diag) Error![]OutputEntry {
        try c.op(.query_derivation_output_map, d);
        try c.writeStr(drv, d);
        try c.processStderr(on_event, d);
        const n = try c.readU64(d);
        var map: std.ArrayList(OutputEntry) = .empty;
        for (0..n) |_| {
            const name = try c.readStr(arena, d);
            const path = try c.readStr(arena, d);
            if (path.len == 0) {
                try map.append(arena, .{ .name = name, .path = null });
                continue;
            }
            // the answer names paths this client later hands to the user and
            // to `nix build -o`: a store that says /etc/passwd is broken
            _ = StorePath.parse(path, d) catch {
                remote.prefix(d, "the daemon named an output that is not a store path", .{});
                return error.Protocol;
            };
            try map.append(arena, .{ .name = name, .path = path });
        }
        // a BTreeMap: sorted, the last of equal keys wins
        std.mem.sort(OutputEntry, map.items, {}, struct {
            fn lt(_: void, x: OutputEntry, y: OutputEntry) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        var kept: usize = 0;
        for (map.items) |e| {
            if (kept > 0 and std.mem.eql(u8, map.items[kept - 1].name, e.name)) {
                map.items[kept - 1] = e;
                continue;
            }
            map.items[kept] = e;
            kept += 1;
        }
        return map.items[0..kept];
    }

    /// `AddIndirectRoot` (uds-remote-store.cc:addIndirectRoot): registers
    /// `path`, an existing symlink into the store that the caller created,
    /// as a GC root. The daemon links `/nix/var/nix/gcroots/auto/<hash>` to it.
    pub fn addIndirectRoot(c: *Connection, path: []const u8, on_event: Sink, d: *Diag) Error!void {
        try c.op(.add_indirect_root, d);
        try c.writeStr(path, d);
        try c.processStderr(on_event, d);
        // uds-remote-store.cc:addIndirectRoot: readInt
        _ = try c.conn(wire.readNum(c.from, std.math.maxInt(u32), d), d);
    }

    /// `QuerySubstitutablePathInfos` (the protocol >= 1.22 shape, no content
    /// addresses): the subset of `paths` some substituter has.
    pub fn querySubstitutablePathInfos(c: *Connection, arena: Allocator, paths: []const StorePath, on_event: Sink, d: *Diag) Error![]StorePath {
        try c.op(.query_substitutable_path_infos, d);
        try c.writeU64(paths.len, d);
        var buf: [path_mod.max_base_len + 256]u8 = undefined;
        for (paths) |*p| {
            try c.writeStr(p.print(&buf), d);
            try c.writeStr("", d);
        }
        try c.processStderr(on_event, d);
        const n = try c.readU64(d);
        var out: std.ArrayList(StorePath) = try .initCapacity(arena, @min(n, 1 << 10));
        for (0..n) |_| {
            const path = try c.conn(wire.readStorePath(c.from, arena, d), d);
            _ = c.scratch.reset(.retain_capacity);
            const a = c.scratch.allocator();
            _ = try c.conn(wire.readOptPath(c.from, a, d), d); // deriver
            _ = try c.readPaths(a, d); // references
            _ = try c.readU64(d); // download size
            _ = try c.readU64(d); // NAR size
            try out.append(arena, path);
        }
        return out.items;
    }

    /// indirect-root-store.cc:addPermRoot: a symlink at `root` to
    /// `store_path`, then `AddIndirectRoot`.
    pub fn addPermRoot(c: *Connection, store_path: []const u8, root: []const u8, d: *Diag) Error!void {
        const sd = path_mod.store_dir;
        if (std.mem.startsWith(u8, root, sd) and (root.len == sd.len or root[sd.len] == '/'))
            return d.fail(error.Protocol, "creating a garbage collector root ({s}) in the Nix store is forbidden", .{root});
        try freeForARoot(c.io, root, d);
        replaceSymlink(c.gpa, c.io, store_path, root) catch |e| return remote.failIo(d, e, "cannot create {s}", .{root});
        try c.addIndirectRoot(root, .ignore, d);
    }

    /// `NarFromPath`: the connection's reader, at the NAR. The caller reads
    /// exactly the NAR before the next op, and reports a failure of that
    /// read with `narFail`.
    pub fn narReader(c: *Connection, path: *const StorePath, on_event: Sink, d: *Diag) Error!*Reader {
        var buf: [path_mod.max_base_len + 256]u8 = undefined;
        return c.narStart(path.print(&buf), on_event, d);
    }

    fn narStart(c: *Connection, path: []const u8, on_event: Sink, d: *Diag) Error!*Reader {
        try c.op(.nar_from_path, d);
        try c.writeStr(path, d);
        try c.processStderr(on_event, d);
        return c.from;
    }

    /// A failure while reading `narReader`'s NAR, under the connection's
    /// context: a failed read is the stream's own error, and a message
    /// already in `d` is wrapped.
    pub fn narFail(c: *Connection, e: anyerror, d: *Diag) Error {
        if (e == error.ReadFailed or e == error.EndOfStream)
            return remote.failIo(d, c.streamErr(true) orelse e, "daemon connection", .{});
        if (d.msg == null) return remote.failIo(d, e, "daemon connection", .{});
        remote.prefix(d, "daemon connection", .{});
        return error.Io;
    }
};

/// indirect-root-store.cc:addPermRoot: a root replaces nothing but a symlink
/// that already points into the store. Everything else stays as it is.
pub fn freeForARoot(io: Io, root: []const u8, d: *Diag) Error!void {
    const st = Io.Dir.cwd().statFile(io, root, .{ .follow_symlinks = false }) catch return;
    if (st.kind == .sym_link) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (Io.Dir.cwd().readLink(io, root, &buf)) |n| {
            const t = buf[0..n];
            const sd = path_mod.store_dir;
            if (std.mem.startsWith(u8, t, sd) and t.len > sd.len and t[sd.len] == '/') return;
        } else |_| {}
    }
    return d.fail(error.Store, "cannot create symlink \"{s}\"; already exists", .{root});
}

/// file-system.cc:replaceSymlink: a temporary link renamed over `link`.
pub fn replaceSymlink(gpa: Allocator, io: Io, target: []const u8, link: []const u8) !void {
    const parent = std.fs.path.dirname(link) orelse "/";
    try Io.Dir.cwd().createDirPath(io, parent);
    const name = std.fs.path.basename(link);
    var n: usize = 0;
    while (true) : (n += 1) {
        const tmp = try std.fmt.allocPrint(gpa, "{s}/.{d}_{s}", .{ parent, n, name });
        defer gpa.free(tmp);
        Io.Dir.cwd().symLink(io, target, tmp, .{}) catch |e| switch (e) {
            error.PathAlreadyExists => continue,
            else => return e,
        };
        Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), link, io) catch |e| {
            Io.Dir.cwd().deleteFile(io, tmp) catch {};
            return e;
        };
        return;
    }
}

pub fn failedEvent(drv_path: []const u8, reason: []const u8) Event {
    return .{ .failed = .{ .drv_path = drv_path, .reason = reason } };
}

// Tests

const testing = std.testing;

test "a status over a byte is not a success" {
    const r = struct {
        fn f(status: u64) BuildResult {
            return .{ .path = "", .status = status, .msg = "" };
        }
    }.f;
    try testing.expect(r(0).success() and r(13).success());
    try testing.expect(!r(256).success() and !r(269).success() and !r(3).success());
}

fn progressFields(fields: [4]u64) [4]Field {
    var out: [4]Field = undefined;
    for (fields, &out) |n, *f| f.* = .{ .int = n };
    return out;
}

// The order the daemon sent for two builds, one failing then one built.
test "each change is a verdict in order" {
    var c: BuildCounts = .{};
    defer c.pending.deinit(testing.allocator);
    try c.progress(testing.allocator, &progressFields(.{ 0, 3, 2, 0 }));
    try testing.expectEqual(0, c.pendingSlice().len);
    try c.progress(testing.allocator, &progressFields(.{ 0, 3, 2, 1 }));
    try c.progress(testing.allocator, &progressFields(.{ 1, 3, 1, 1 }));
    try testing.expectEqualSlices(bool, &.{ false, true }, c.pendingSlice());
}

test "a repeated update claims nothing" {
    var c: BuildCounts = .{};
    defer c.pending.deinit(testing.allocator);
    try c.progress(testing.allocator, &progressFields(.{ 1, 3, 1, 0 }));
    try c.progress(testing.allocator, &progressFields(.{ 1, 3, 1, 0 }));
    try testing.expectEqualSlices(bool, &.{true}, c.pendingSlice());
}

test "transport from url" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(default_socket_path, Transport.parse(a, "daemon", null).?.unix);
    try testing.expectEqualStrings("/tmp/s", Transport.parse(a, "unix:///tmp/s", null).?.unix);
    // nix.conf's default `store`, which `builder` falls back to.
    try testing.expectEqualStrings(default_socket_path, Transport.parse(a, "auto", null).?.unix);
    try testing.expectEqualStrings(default_socket_path, Transport.parse(a, "", null).?.unix);
    const s = Transport.parse(a, "ssh-ng://bob@builder.example", null).?.ssh;
    try testing.expectEqualStrings("bob", s.user.?);
    try testing.expectEqualStrings("builder.example", s.host);
    try testing.expectEqual(null, s.port);
    try testing.expectEqual(2, s.remote_program.len);
    try testing.expectEqualStrings("nix-daemon", s.remote_program[0]);
    try testing.expectEqualStrings("--stdio", s.remote_program[1]);
    try testing.expectEqual(null, s.key);
    try testing.expect(!s.compress);
    try testing.expectEqualStrings("builder.example", Transport.parse(a, "ssh-ng://builder.example/", null).?.ssh.host);
    // ssh-store.cc appends --stdio to whatever remote-program names
    const rp = Transport.parse(a, "ssh-ng://builder.example?remote-program=nix-daemon%20--store%20local%3Froot%3D/tmp/s", null).?.ssh.remote_program;
    try testing.expectEqual(4, rp.len);
    for ([_][]const u8{ "nix-daemon", "--store", "local?root=/tmp/s", "--stdio" }, rp) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(2222, Transport.parse(a, "ssh-ng://builder.example:2222", null).?.ssh.port.?);
    try testing.expectEqualStrings("::1", Transport.parse(a, "ssh-ng://[::1]:2222", null).?.ssh.host);
    try testing.expectEqualStrings("::1", Transport.parse(a, "ssh-ng://[::1]", null).?.ssh.host);
    try testing.expectEqualStrings("/k", Transport.parse(a, "ssh-ng://h?ssh-key=/k&compress=true", null).?.ssh.key.?);
    try testing.expect(Transport.parse(a, "ssh-ng://h?compress=true", null).?.ssh.compress);
    try testing.expectEqual(null, Transport.parse(a, "http://127.0.0.1:9455", null));
}

// An ssh host that starts with `-` would be an ssh option, so it never
// reaches the command line.
test "an ssh host is never an option" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    for ([_][]const u8{ "ssh-ng://-oProxyCommand=touch%20/tmp/pwned", "ssh-ng://-l", "ssh-ng://-u@h", "ssh-ng://@h", "ssh-ng://" }) |url|
        try testing.expectEqual(null, Transport.parse(arena_state.allocator(), url, null));
}

test "an ssh host that is an option says so" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    try testing.expectError(error.Usage, Transport.parseChecked(arena_state.allocator(), "ssh-ng://-oProxyCommand=x", "x86_64-linux", null, &d));
    try testing.expect(std.mem.indexOf(u8, d.message(), "must not start with '-'") != null);
}

test "ssh argv puts the host first" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const t = Transport.parse(a, "ssh-ng://bob@h:2222?ssh-key=/k&compress=true", null).?;
    const args = try sshArgs(a, t.ssh, null, &d);
    const want = [_][]const u8{ "bob@h", "-x", "-i", "/k", "-C", "-p2222" };
    try testing.expectEqual(want.len, args.len);
    for (want, args) |x, y| try testing.expectEqualStrings(x, y);
}

test "NIX_SSHOPTS split like a shell" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var d: Diag = .init(testing.allocator);
    defer d.deinit();
    const got = try shellSplit(a, "-o \"Proxy Command=a b\" -i 'my key'", &d);
    const want = [_][]const u8{ "-o", "Proxy Command=a b", "-i", "my key" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |x, y| try testing.expectEqualStrings(x, y);
    const got2 = try shellSplit(a, "a\\ b  c", &d);
    try testing.expectEqual(2, got2.len);
    try testing.expectEqualStrings("a b", got2[0]);
    try testing.expectEqualStrings("c", got2[1]);
    try testing.expectEqual(0, (try shellSplit(a, "  ", &d)).len);
    try testing.expectError(error.Usage, shellSplit(a, "'a", &d));
}

test "the uri names the default socket daemon" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try Transport.parse(a, "daemon", null).?.uri(&w, null);
    try testing.expectEqualStrings("daemon", w.buffered());
    w = .fixed(&buf);
    try Transport.parse(a, "ssh-ng://bob@h:22", null).?.uri(&w, null);
    try testing.expectEqualStrings("ssh-ng://bob@h", w.buffered());
}

test {
    _ = @import("worker/daemon_tests.zig");
}
