//! A source position for the evaluator: a byte offset into the
//! concatenation of every loaded source, so one `u32` names file, line and
//! column. The AST keeps file-local `Span`s; the compiler adds the file's
//! base offset.

const std = @import("std");

pub const Pos = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn at(off: u32) Pos {
        std.debug.assert(off != std.math.maxInt(u32));
        return @fromBackingInt(@intCast(off));
    }

    pub fn offset(p: Pos) ?u32 {
        return if (p == .none) null else @backingInt(p);
    }
};
