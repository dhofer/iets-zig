//! Arithmetic, bitwise and comparison primops.

const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const Value = @import("../runtime/value.zig").Value;
const Pos = @import("../syntax/pos.zig").Pos;

pub const ops = [_]Op{
    .{ .name = "__add", .arity = 2, .f = arith(.add) },
    .{ .name = "__sub", .arity = 2, .f = arith(.sub) },
    .{ .name = "__mul", .arity = 2, .f = arith(.mul) },
    .{ .name = "__div", .arity = 2, .f = arith(.div) },
    .{ .name = "__bitAnd", .arity = 2, .f = bitwise("bitAnd") },
    .{ .name = "__bitOr", .arity = 2, .f = bitwise("bitOr") },
    .{ .name = "__bitXor", .arity = 2, .f = bitwise("bitXor") },
    .{ .name = "__lessThan", .arity = 2, .f = lessThan },
};

fn arith(comptime op: Evaluator.ArithOp) *const Evaluator.PrimFn {
    return struct {
        fn f(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
            return ev.arith(args[0], args[1], op, pos);
        }
    }.f;
}

fn bitwise(comptime name: []const u8) *const Evaluator.PrimFn {
    return struct {
        fn f(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
            const a = try ev.forceInt(args[0], pos, "while evaluating the first argument passed to builtins." ++ name);
            const b = try ev.forceInt(args[1], pos, "while evaluating the second argument passed to builtins." ++ name);
            return ev.mkInt(switch (name[3]) {
                'A' => a & b,
                'O' => a | b,
                'X' => a ^ b,
                else => unreachable,
            });
        }
    }.f;
}

fn lessThan(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    return .fromBool(try ev.lessThan(args[0], args[1], pos));
}
