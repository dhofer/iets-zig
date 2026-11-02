const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("iets", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Caches key their entries on this, so an edit to the sources never
    // reads what another build wrote. Rust's `IETS_BUILD_ID` (build.rs).
    const options = b.addOptions();
    options.addOption([]const u8, "build_id", buildId(b));
    // `iets --version`, Cargo.toml's version of the Rust tree this ports
    options.addOption([]const u8, "version", "0.2.0");
    // for the layering test, which reads src/cli (src/cli/layering.zig)
    options.addOption([]const u8, "src_dir", srcDir(b));
    // The memory census of `IETS_STATS=2` (src/runtime/census.zig); off,
    // the build carries none of its hooks.
    options.addOption(bool, "stats2", b.option(bool, "stats2", "Compile in the IETS_STATS=2 memory census") orelse false);
    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "iets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "iets", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run iets").dependOn(&run_cmd.step);

    // Frontends on the library alone (docs/reference/library.md): not part
    // of the default install; `zig build examples` builds them all,
    // `zig build example-NAME` one.
    const examples = b.step("examples", "Build the library examples");
    for ([_][]const u8{ "eval", "value", "drv_info", "build", "nar_bench" }) |name| {
        const ex = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "iets", .module = mod }},
            }),
        });
        const install = b.addInstallArtifact(ex, .{});
        b.step(b.fmt("example-{s}", .{name}), b.fmt("Build examples/{s}.zig", .{name})).dependOn(&install.step);
        examples.dependOn(&install.step);
    }

    const filters = b.option([]const []const u8, "test-filter", "Only run tests matching") orelse &.{};
    const mod_tests = b.addTest(.{ .root_module = mod, .filters = filters });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(mod_tests).step);
}

/// The absolute path of `src`.
fn srcDir(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const root = b.root.root_dir.handle.openDir(io, if (b.root.sub_path.len == 0) "." else b.root.sub_path, .{}) catch @panic("cannot open the build root");
    return root.realPathFileAlloc(io, "src", b.allocator) catch @panic("cannot resolve src");
}

/// SHA-256 over every file under `src` in path order, and the build files.
fn buildId(b: *std.Build) []const u8 {
    const io = b.graph.io;
    const root = b.root.root_dir.handle.openDir(io, if (b.root.sub_path.len == 0) "." else b.root.sub_path, .{}) catch @panic("cannot open the build root");
    var paths: std.ArrayList([]const u8) = .empty;
    var src = root.openDir(io, "src", .{ .iterate = true }) catch @panic("cannot open src");
    defer src.close(io);
    var walk = src.walk(b.allocator) catch @panic("out of memory");
    defer walk.deinit();
    // The configure step is cached: name every input, so an edit, a new
    // file or a removed one configures again and changes the id.
    b.dependOnDirectoryContents(b.path("src"));
    while (walk.next(io) catch @panic("cannot walk src")) |e| switch (e.kind) {
        .file => paths.append(b.allocator, b.fmt("src/{s}", .{e.path})) catch @panic("out of memory"),
        .directory => b.dependOnDirectoryContents(b.path(b.fmt("src/{s}", .{e.path}))),
        else => {},
    };
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    paths.appendSlice(b.allocator, &.{ "build.zig", "build.zig.zon" }) catch @panic("out of memory");
    var h: std.crypto.hash.sha2.Sha256 = .init(.{});
    for (paths.items) |p| {
        b.dependOnFileContents(b.path(p));
        const bytes = root.readFileAlloc(io, p, b.allocator, .unlimited) catch @panic("cannot read a source");
        h.update(p);
        h.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, bytes.len)));
        h.update(bytes);
    }
    return b.fmt("{x}", .{h.finalResult()});
}
