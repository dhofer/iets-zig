//! The evaluator: IR, forcing, application, printing.

pub const ir = @import("eval/ir.zig");
pub const Evaluator = @import("eval/Evaluator.zig");
pub const Files = @import("eval/Files.zig");
pub const print = @import("eval/print.zig");
pub const import = @import("eval/import.zig");
pub const stats = @import("eval/stats.zig");

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Evaluator);
    std.testing.refAllDecls(@import("runtime/value.zig"));
    std.testing.refAllDecls(@import("runtime/Arena.zig"));
    _ = @import("eval/tests.zig");
}
