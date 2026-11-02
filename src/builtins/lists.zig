//! List primops.

const std = @import("std");
const Op = @import("../builtins.zig").Op;
const Evaluator = @import("../eval/Evaluator.zig");
const Error = Evaluator.Error;
const value = @import("../runtime/value.zig");
const Value = value.Value;
const List = value.List;
const Bits = @import("Bits.zig");
const Pos = @import("../syntax/pos.zig").Pos;

pub const ops = [_]Op{
    .{ .name = "__head", .arity = 1, .f = head },
    .{ .name = "__tail", .arity = 1, .f = tail },
    .{ .name = "__length", .arity = 1, .f = length },
    .{ .name = "__elem", .arity = 2, .f = elem },
    .{ .name = "__elemAt", .arity = 2, .f = elemAt },
    .{ .name = "map", .arity = 2, .f = map },
    .{ .name = "__filter", .arity = 2, .f = filter },
    .{ .name = "__foldl'", .arity = 3, .f = foldlStrict },
    .{ .name = "__concatLists", .arity = 1, .f = concatLists },
    .{ .name = "__concatMap", .arity = 2, .f = concatMap },
    .{ .name = "__genList", .arity = 2, .f = genList },
    .{ .name = "__any", .arity = 2, .f = anyAll(true) },
    .{ .name = "__all", .arity = 2, .f = anyAll(false) },
    .{ .name = "__sort", .arity = 2, .f = sort },
    .{ .name = "__partition", .arity = 2, .f = partition },
};

fn listValue(l: *List) Value {
    return .fromPtr(.ptr, l);
}

fn head(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[0], pos, "while evaluating the first argument passed to builtins.head");
    if (l.len == 0) return ev.fail(.eval, pos, "'builtins.head' called on an empty list", .{});
    return ev.forceCell(&l.cells()[0]);
}

fn tail(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[0], pos, "while evaluating the first argument passed to builtins.tail");
    if (l.len == 0) return ev.fail(.eval, pos, "'builtins.tail' called on an empty list", .{});
    const out = try ev.allocList(l.len - 1);
    @memcpy(out.raw(), l.cells()[1..]);
    return listValue(out);
}

fn length(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[0], pos, "while evaluating the first argument passed to builtins.length");
    return .immInt(l.len);
}

fn elem(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.elem");
    ev.offerList(l);
    for (l.cells()) |*c| {
        const x = try ev.force(args[0]);
        const raw = c.get();
        const y = try ev.forceCell(c);
        // Nix compares the two slots, and one slot is equal to itself even
        // when it holds a function.
        if (x == y and (raw == args[0] or x.typeOf() != .lambda)) return .true;
        if (try ev.eqValues(x, y, pos)) return .true;
    }
    return .false;
}

fn elemAt(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[0], pos, "while evaluating the first argument passed to builtins.elemAt");
    const n = try ev.forceInt(args[1], pos, "while evaluating the second argument passed to builtins.elemAt");
    if (n < 0 or n >= l.len)
        return ev.fail(.eval, pos, "'builtins.elemAt' called with index {d} on a list of size {d}", .{ n, l.len });
    return ev.forceCell(&l.cells()[@intCast(n)]);
}

fn map(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.map");
    if (l.len == 0) return listValue(l);
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.map");
    const out = try ev.allocList(l.len);
    for (out.raw(), l.cells()) |*o, c| o.* = .init(try ev.mkThunkApp(f, c.get()));
    return listValue(out);
}

fn filter(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.filter");
    ev.offerList(l);
    if (l.len == 0) return listValue(l);
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.filter");
    var bits: Bits = try .init(ev.gpa, l.len);
    defer bits.deinit(ev.gpa);
    var n: usize = 0;
    for (l.cells(), 0..) |c, i| {
        const r = try ev.call1(f, c.get(), pos);
        if (try ev.forceBool(r, pos, "while evaluating the return value of the filtering function passed to builtins.filter")) {
            bits.set(i);
            n += 1;
        }
    }
    if (n == l.len) return listValue(l);
    return listValue(try pick(ev, l, &bits, n, true));
}

/// The `n` elements of `l` whose bit is `want`, in order, as a new list.
fn pick(ev: *Evaluator, l: *List, bits: *Bits, n: usize, want: bool) Error!*List {
    const out = try ev.allocList(n);
    const dst = out.raw();
    var k: usize = 0;
    for (l.cells(), 0..) |c, i| if (bits.isSet(i) == want) {
        dst[k] = .init(c.get());
        k += 1;
    };
    return out;
}

fn foldlStrict(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.foldlStrict");
    const l = try ev.forceList(args[2], pos, "while evaluating the third argument passed to builtins.foldlStrict");
    ev.offerList(l);
    var acc = args[1];
    // Each call's result is forced, so the accumulator never builds a thunk chain.
    for (l.cells()) |c| acc = try ev.call2(f, acc, c.get(), pos);
    return ev.force(acc);
}

fn concatLists(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[0], pos, "while evaluating the first argument passed to builtins.concatLists");
    ev.offerList(l);
    const lists = try ev.gpa.alloc(*List, l.len);
    defer ev.gpa.free(lists);
    for (l.cells(), lists) |c, *o|
        o.* = try ev.forceList(c.get(), pos, "while evaluating a value of the list passed to builtins.concatLists");
    return ev.concatLists(lists);
}

fn concatMap(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.concatMap");
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.concatMap");
    ev.offerList(l);
    const lists = try ev.gpa.alloc(*List, l.len);
    defer ev.gpa.free(lists);
    for (l.cells(), lists) |c, *o| {
        const r = try ev.call1(f, c.get(), pos);
        o.* = try ev.forceList(r, pos, "while evaluating the return value of the function passed to builtins.concatMap");
    }
    return ev.concatLists(lists);
}

fn genList(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const n = try ev.forceInt(args[1], pos, "while evaluating the second argument passed to builtins.genList");
    if (n < 0) return ev.fail(.eval, pos, "cannot create list of size {d}", .{n});
    if (n > std.math.maxInt(u32)) return ev.fail(.eval, pos, "out of memory", .{});
    const f = try ev.forceFunction(args[0], .none, "while evaluating the first argument passed to builtins.genList");
    const out = try ev.allocList(@intCast(n));
    for (out.raw(), 0..) |*c, i| c.* = .init(try ev.mkThunkApp(f, .immInt(@intCast(i))));
    return listValue(out);
}

/// `any` when `want` is true, `all` when false: stop at the first result equal to `want`.
fn anyAll(comptime want: bool) *const Evaluator.PrimFn {
    const name = if (want) "any" else "all";
    return struct {
        fn f(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
            const func = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins." ++ name);
            const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins." ++ name);
            ev.offerList(l);
            for (l.cells()) |c| {
                const r = try ev.call1(func, c.get(), pos);
                if (try ev.forceBool(r, pos, "while evaluating the return value of the function passed to builtins." ++ name) == want)
                    return .fromBool(want);
            }
            return .fromBool(!want);
        }
    }.f;
}

fn partition(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.partition");
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.partition");
    ev.offerList(l);
    var bits: Bits = try .init(ev.gpa, l.len);
    defer bits.deinit(ev.gpa);
    var n: usize = 0;
    for (l.cells(), 0..) |*c, i| {
        const r = try ev.call1(f, try ev.forceCell(c), pos);
        if (try ev.forceBool(r, pos, "while evaluating the return value of the partition function passed to builtins.partition")) {
            bits.set(i);
            n += 1;
        }
    }
    var entries = [_]value.Attr{
        .{ .sym = ev.s.right, .pos = .none, .cell = .init(listValue(try pick(ev, l, &bits, n, true))) },
        .{ .sym = ev.s.wrong, .pos = .none, .cell = .init(listValue(try pick(ev, l, &bits, l.len - n, false))) },
    };
    return ev.mkAttrs(&entries, pos);
}

fn sort(ev: *Evaluator, args: []const Value, pos: Pos) Error!Value {
    const l = try ev.forceList(args[1], pos, "while evaluating the second argument passed to builtins.sort");
    ev.offerList(l);
    if (l.len == 0) return listValue(l);
    const f = try ev.forceFunction(args[0], pos, "while evaluating the first argument passed to builtins.sort");
    const out = try ev.allocList(l.len);
    const items = try ev.gpa.alloc(Value, l.len);
    defer ev.gpa.free(items);
    for (l.cells(), items) |*c, *it| it.* = try ev.forceCell(c);
    var s: Sorter = .{
        .ev = ev,
        .f = f,
        .pos = pos,
        .is_less_than = f.kind() == .primop and std.mem.eql(u8, f.as(value.PrimOp).name(), "__lessThan"),
        .buf = try ev.gpa.alloc(Value, l.len),
    };
    defer ev.gpa.free(s.buf);
    try s.peeksort(items);
    for (out.raw(), items) |*c, v| c.* = .init(v);
    return listValue(out);
}

/// Mirrors sort.hh:peeksort. The order of the comparator's calls is
/// observable: a comparator that is no strict weak order, or that fails on
/// one pair, must give the answer Nix gives.
const Sorter = struct {
    ev: *Evaluator,
    f: Value,
    pos: Pos,
    is_less_than: bool,
    /// Scratch for merges, as long as the list.
    buf: []Value,

    /// libstdc++'s cut-off, which Nix's peeksort copies.
    const insertion_sort_max = 16;

    fn less(s: *Sorter, a: Value, b: Value) Error!bool {
        if (s.is_less_than) return s.ev.lessThan(a, b, s.pos);
        const r = try s.ev.call2(s.f, a, b, s.pos);
        return s.ev.forceBool(r, s.pos, "while evaluating the return value of the sorting function passed to builtins.sort");
    }

    fn peeksort(s: *Sorter, v: []Value) Error!void {
        switch (v.len) {
            0, 1 => {},
            2 => if (try s.less(v[1], v[0])) std.mem.swap(Value, &v[0], &v[1]),
            else => try s.sortRange(v, 0, v.len, 0, v.len),
        }
    }

    fn insertionSort(s: *Sorter, v: []Value) Error!void {
        for (1..v.len) |current| {
            var k = current;
            while (k > 0 and try s.less(v[k], v[k - 1])) : (k -= 1)
                std.mem.swap(Value, &v[k], &v[k - 1]);
        }
    }

    /// sort.hh:mergeSortedRunsInPlace on `v[begin..end]`, split at `middle`.
    fn merge(s: *Sorter, v: []Value, begin: usize, middle: usize, end: usize) Error!void {
        const buf = s.buf[0 .. end - begin];
        @memcpy(buf, v[begin..end]);
        const split = middle - begin;
        var l: usize = 0;
        var r: usize = split;
        var o: usize = begin;
        while (l < split and r < buf.len) : (o += 1) {
            // Not-less keeps the sort stable: a tie takes the left element.
            if (try s.less(buf[r], buf[l])) {
                v[o] = buf[r];
                r += 1;
            } else {
                v[o] = buf[l];
                l += 1;
            }
        }
        @memcpy(v[o..][0 .. split - l], buf[l..split]);
        o += split - l;
        @memcpy(v[o..][0 .. buf.len - r], buf[r..]);
    }

    /// Maximal `i` with `v[begin..i]` strictly decreasing; `rev` negates the
    /// comparator, which gives `weaklyIncreasingPrefix`.
    fn runPrefix(s: *Sorter, v: []const Value, begin_in: usize, end: usize, rev: bool) Error!usize {
        if (begin_in == end) return begin_in;
        var begin = begin_in;
        while (begin + 1 != end and try s.less(v[begin + 1], v[begin]) != rev) begin += 1;
        return begin + 1;
    }

    /// Minimal `i` with `v[i..end]` strictly decreasing; `rev` as in `runPrefix`.
    fn runSuffix(s: *Sorter, v: []const Value, begin: usize, end_in: usize, rev: bool) Error!usize {
        if (begin == end_in) return end_in;
        var end = end_in;
        while (end - 1 > begin and try s.less(v[end - 1], v[end - 2]) != rev) end -= 1;
        return end - 1;
    }

    /// Sort `v[begin..end]`, given that `v[begin..left_run_end]` and
    /// `v[right_run_begin..end]` are sorted.
    fn sortRange(s: *Sorter, v: []Value, begin: usize, end: usize, left_run_end: usize, right_run_begin: usize) Error!void {
        if (left_run_end == end or right_run_begin == begin) return;
        const len = end - begin;
        if (len <= insertion_sort_max) return s.insertionSort(v[begin..end]);
        const middle = begin + len / 2;
        if (middle <= left_run_end) {
            try s.sortRange(v, left_run_end, end, left_run_end + 1, right_run_begin);
            return s.merge(v, begin, left_run_end, end);
        }
        if (middle >= right_run_begin) {
            try s.sortRange(v, begin, right_run_begin, left_run_end, right_run_begin - 1);
            return s.merge(v, begin, right_run_begin, end);
        }
        // The run that holds middle - 1.
        const up = !try s.less(v[middle], v[middle - 1]);
        const i = try s.runSuffix(v, left_run_end, middle, up);
        const j = try s.runPrefix(v, middle - 1, right_run_begin, up);
        if (!up) std.mem.reverse(Value, v[i..j]);
        if (i == begin and j == end) return;
        if (middle - i < j - middle) {
            try s.sortRange(v, begin, i, left_run_end, i -% 1);
            try s.sortRange(v, i, end, j, right_run_begin);
            return s.merge(v, begin, i, end);
        }
        try s.sortRange(v, begin, j, left_run_end, i);
        try s.sortRange(v, j, end, j + 1, right_run_begin);
        return s.merge(v, begin, j, end);
    }
};
