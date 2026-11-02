//! The documentation an installed binary carries: `iets help TOPIC`.
//!
//! The reference quadrant is embedded, so a binary answers `iets help
//! settings` with no `docs/` directory in sight. The pages under `docs/`
//! here are copies of ../iets/docs/reference (`scripts/cli-parity.sh`
//! checks they are current). The other quadrants stay in the Rust
//! repository and their topics print the path they live at.

const std = @import("std");
const Session = @import("../session.zig").Session;
const help = @import("help.zig");

/// One documentation page `iets help` can be asked for.
pub const Page = struct {
    /// The bare topic name, which is also the file's base name.
    topic: []const u8,
    /// The directory under `docs/`; it also qualifies the topic, so
    /// `reference/plumbing` names the page and `plumbing` the command.
    quadrant: []const u8,
    /// One line for the topic list.
    about: []const u8,
    /// The page itself, when the binary carries it.
    text: ?[]const u8 = null,
};

/// Every page, embedded ones first.
pub const pages = [_]Page{
    .{ .topic = "commands", .quadrant = "reference", .about = "every command, its flags and its exit codes", .text = @embedFile("docs/commands.md") },
    .{ .topic = "plumbing", .quadrant = "reference", .about = "the machine-first operations and their JSON", .text = @embedFile("docs/plumbing.md") },
    .{ .topic = "classic", .quadrant = "reference", .about = "the classic Nix names and the fallback rules", .text = @embedFile("docs/classic.md") },
    .{ .topic = "builders", .quadrant = "reference", .about = "builder URLs, the worker protocol, grpc and NAR", .text = @embedFile("docs/builders.md") },
    .{ .topic = "flakes", .quadrant = "reference", .about = "flake references, getFlake and the fetchers", .text = @embedFile("docs/flakes.md") },
    .{ .topic = "settings", .quadrant = "reference", .about = "iets.toml, the IETS_* variables and nix.conf", .text = @embedFile("docs/settings.md") },
    .{ .topic = "events", .quadrant = "reference", .about = "the JSON event stream of 'IETS_EVENTS'", .text = @embedFile("docs/events.md") },
    .{ .topic = "profile", .quadrant = "reference", .about = "the sampled flame graph of 'IETS_PROFILE=eval'", .text = @embedFile("docs/profile.md") },
    .{ .topic = "errors", .quadrant = "reference", .about = "the error codes, the exit codes and the log records", .text = @embedFile("docs/errors.md") },
    .{ .topic = "lints", .quadrant = "reference", .about = "every lint, its level and its trigger", .text = @embedFile("docs/lints.md") },
    .{ .topic = "syntax-tree", .quadrant = "reference", .about = "the JSON of 'iets parse --json'", .text = @embedFile("docs/syntax-tree.md") },
    .{ .topic = "builtins", .quadrant = "reference", .about = "every builtin and how well it works", .text = @embedFile("docs/builtins.md") },
    .{ .topic = "divergences", .quadrant = "reference", .about = "where iets differs from Nix 2.34.8", .text = @embedFile("docs/divergences.md") },
    .{ .topic = "fuzz", .quadrant = "reference", .about = "what each fuzz target compares", .text = @embedFile("docs/fuzz.md") },
    .{ .topic = "library", .quadrant = "reference", .about = "the crate's entry points, for a frontend", .text = @embedFile("docs/library.md") },
    .{ .topic = "getting-started", .quadrant = "tutorial", .about = "install it and evaluate something" },
    .{ .topic = "build-remotely", .quadrant = "how-to", .about = "send the builds to another machine" },
    .{ .topic = "use-with-direnv", .quadrant = "how-to", .about = "a dev shell that loads itself" },
    .{ .topic = "replace-nix-tools", .quadrant = "how-to", .about = "put the classic mode commands on PATH" },
    .{ .topic = "fix-hashes", .quadrant = "how-to", .about = "let a build write the hash it got" },
    .{ .topic = "script-iets", .quadrant = "how-to", .about = "drive it from a program" },
    .{ .topic = "write-lint-rules", .quadrant = "how-to", .about = "your own lint rules" },
    .{ .topic = "embed-the-evaluator", .quadrant = "how-to", .about = "link the library" },
    .{ .topic = "evaluation", .quadrant = "explanation", .about = "how the evaluator works" },
    .{ .topic = "caching", .quadrant = "explanation", .about = "what the caches hold and key on" },
    .{ .topic = "flakes-and-sources", .quadrant = "explanation", .about = "where a tree comes from" },
    .{ .topic = "plumbing-and-porcelain", .quadrant = "explanation", .about = "why the operations exist" },
    .{ .topic = "provenance", .quadrant = "explanation", .about = "store paths back to local trees" },
    .{ .topic = "dev-shells", .quadrant = "explanation", .about = "how print-dev-env makes a shell" },
    .{ .topic = "transports", .quadrant = "explanation", .about = "the build transports, measured" },
    .{ .topic = "lint-scope", .quadrant = "explanation", .about = "what iets lints, and why" },
    .{ .topic = "history", .quadrant = "explanation", .about = "how it got here" },
};

/// The page `name` asks for: the bare topic, or `quadrant/topic`.
pub fn find(name: []const u8) ?*const Page {
    for (&pages) |*p| {
        if (std.mem.eql(u8, p.topic, name)) return p;
        if (std.mem.startsWith(u8, name, p.quadrant) and name.len == p.quadrant.len + 1 + p.topic.len and
            name[p.quadrant.len] == '/' and std.mem.endsWith(u8, name, p.topic)) return p;
    }
    return null;
}

/// The topic block of `iets help`.
pub fn list(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("\ntopics: 'iets help TOPIC' prints a page\n");
    for (pages) |p| try w.print("{c} {s:<22} {s}\n", .{ @as(u8, if (p.text != null) ' ' else '*'), p.topic, p.about });
    try w.writeAll("\n* is a page this binary does not carry: it is docs/<quadrant>/<topic>.md\n  in the iets repository, and 'iets help TOPIC' prints that path.\n");
}

/// Prints the page, or where it lives when the binary does not carry it;
/// the exit code.
pub fn show(s: *Session, p: *const Page) u8 {
    if (p.text) |t| return help.out(s, t);
    var buf: [512]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "'{0s}' is docs/{1s}/{0s}.md in the iets repository.\nThis binary carries the reference pages only; 'iets help' lists them.\n", .{ p.topic, p.quadrant }) catch return 1;
    return help.out(s, t);
}

const testing = std.testing;

test "every embedded page has a heading" {
    for (pages) |p| {
        const t = p.text orelse continue;
        try testing.expect(std.mem.startsWith(u8, t, "# "));
        try testing.expect(t.len > 1000);
    }
}

test "topics resolve bare and qualified" {
    try testing.expectEqualStrings("settings", find("settings").?.topic);
    try testing.expectEqualStrings("plumbing", find("reference/plumbing").?.topic);
    try testing.expectEqualStrings("caching", find("explanation/caching").?.topic);
    try testing.expectEqual(null, find("reference/caching"));
    try testing.expectEqual(null, find("nonesuch"));
}

test "the topic list fits 80 columns" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    try list(&buf.writer);
    var it = std.mem.splitScalar(u8, buf.written(), '\n');
    while (it.next()) |l| try testing.expect(l.len <= 80);
}
