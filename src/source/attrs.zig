//! fetchers::Attrs: an input's attributes in name order.

const std = @import("std");

pub const AttrVal = union(enum) {
    str: []const u8,
    bool: bool,
    int: u64,

    pub fn eql(a: AttrVal, b: AttrVal) bool {
        return switch (a) {
            .str => |s| b == .str and std.mem.eql(u8, s, b.str),
            .bool => |x| b == .bool and x == b.bool,
            .int => |n| b == .int and n == b.int,
        };
    }
};

pub const Attrs = StrMap(AttrVal);

/// A map from strings to `V` kept sorted by key in a plain array: the
/// maps here hold a handful of entries, and every consumer walks them in order.
pub fn StrMap(comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { key: []const u8, value: V };

        entries: std.ArrayList(Entry) = .empty,

        fn find(m: *const Self, k: []const u8) struct { found: bool, i: usize } {
            var lo: usize = 0;
            var hi = m.entries.items.len;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                switch (std.mem.order(u8, m.entries.items[mid].key, k)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => return .{ .found = true, .i = mid },
                }
            }
            return .{ .found = false, .i = lo };
        }

        pub fn get(m: *const Self, k: []const u8) ?V {
            const f = m.find(k);
            return if (f.found) m.entries.items[f.i].value else null;
        }

        pub fn contains(m: *const Self, k: []const u8) bool {
            return m.find(k).found;
        }

        /// Insert or replace.
        pub fn put(m: *Self, a: std.mem.Allocator, k: []const u8, v: V) !void {
            const f = m.find(k);
            if (f.found) {
                m.entries.items[f.i].value = v;
            } else try m.entries.insert(a, f.i, .{ .key = k, .value = v });
        }

        /// Insert unless present: the first of two wins.
        pub fn putFirst(m: *Self, a: std.mem.Allocator, k: []const u8, v: V) !void {
            const f = m.find(k);
            if (!f.found) try m.entries.insert(a, f.i, .{ .key = k, .value = v });
        }

        pub fn remove(m: *Self, k: []const u8) ?V {
            const f = m.find(k);
            if (!f.found) return null;
            return m.entries.orderedRemove(f.i).value;
        }

        pub fn len(m: *const Self) usize {
            return m.entries.items.len;
        }

        pub fn items(m: *const Self) []const Entry {
            return m.entries.items;
        }

        pub fn clone(m: *const Self, a: std.mem.Allocator) !Self {
            return .{ .entries = .fromOwnedSlice(try a.dupe(Entry, m.entries.items)) };
        }
    };
}

pub fn strAttr(a: *const Attrs, name: []const u8) ?[]const u8 {
    return switch (a.get(name) orelse return null) {
        .str => |s| s,
        else => null,
    };
}

test "a StrMap keeps its keys sorted and the first putFirst" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m: Attrs = .{};
    try m.put(a, "b", .{ .int = 1 });
    try m.put(a, "a", .{ .bool = true });
    try m.putFirst(a, "b", .{ .int = 2 });
    try m.put(a, "c", .{ .str = "x" });
    try std.testing.expectEqualStrings("a", m.items()[0].key);
    try std.testing.expectEqual(@as(u64, 1), m.get("b").?.int);
    try std.testing.expectEqualStrings("x", strAttr(&m, "c").?);
    _ = m.remove("a");
    try std.testing.expectEqual(@as(usize, 2), m.len());
}
