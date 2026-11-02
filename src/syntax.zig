//! The front end: interner, lexer, parser, AST, and the `iets parse` dump.
//! The parser keeps raw bindings; attrpath merging and scope resolution
//! happen in `compile`.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Diag = @import("diag.zig").Diag;

pub const symbol = @import("syntax/symbol.zig");
pub const pos = @import("syntax/pos.zig");
pub const ast = @import("syntax/ast.zig");
pub const lexer = @import("syntax/lexer.zig");
pub const parser = @import("syntax/parser.zig");
pub const dump = @import("syntax/dump.zig");
pub const text = @import("syntax/text.zig");

pub const Sym = symbol.Sym;
pub const Interner = symbol.Interner;
pub const Pos = pos.Pos;
pub const Ast = ast.Ast;
pub const Expr = ast.Expr;
pub const ExprId = ast.ExprId;
pub const FileId = ast.FileId;
pub const Span = ast.Span;
pub const Parser = parser.Parser;
pub const Error = parser.Error;
pub const lineCol = text.lineCol;
pub const lineStarts = text.lineStarts;

/// Parse one file. On `error.SyntaxError` the message is in `d` and its
/// byte offset in `err_at`; the message matches Nix's. The caller frees
/// the result with `Ast.deinit`. Deeply nested input recurses deeply: give
/// the thread a large stack (`parser.max_parse_depth`).
pub fn parse(gpa: Allocator, src: []const u8, file: FileId, interner: *Interner, d: *Diag, err_at: *u32) Error!Ast {
    return parseReusing(gpa, .{}, src, file, interner, d, err_at);
}

/// `parse`, reusing the buffers of a previous file's `Ast` (whose contents
/// are discarded; it is freed on error too).
pub fn parseReusing(gpa: Allocator, reuse: Ast, src: []const u8, file: FileId, interner: *Interner, d: *Diag, err_at: *u32) Error!Ast {
    return parseParallel(gpa, reuse, src, file, interner, d, err_at, null);
}

/// `parseReusing`, a huge set's bindings parsed in chunks on `par`.
pub fn parseParallel(gpa: Allocator, reuse: Ast, src: []const u8, file: FileId, interner: *Interner, d: *Diag, err_at: *u32, par: ?*const parser.Parallel) Error!Ast {
    var p: Parser = try .init(gpa, src, interner, reuse, d);
    defer p.deinit();
    p.par = par;
    return p.parseFile(file) catch |e| {
        err_at.* = p.errorOffset();
        return e;
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("syntax/tests.zig");
}
