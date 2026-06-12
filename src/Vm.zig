const std = @import("std");
const Interner = @import("Interner.zig");

const Vm = @This();
const Error = error{RuntimeError};

out: *std.Io.Writer,
globals: std.array_hash_map.Auto(u24, Value),

pub const FnInfo = struct {
    name_id: u24,
    arity: u8,
    entry_point: usize = undefined,
};

pub const Value = union(enum) {
    nil,
    int: i64,

    pub fn format(
        s: @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (s == .nil) {
            try w.writeAll("nil");
        } else {
            try w.print("{d}", .{s.int});
        }
    }
};

const Frame = struct {
    ret_pc: usize,
    saved_frame_base: usize,
};

pub const Inst = packed struct(u32) {
    pub const Op = enum(u8) {
        nil,
        const_int,
        pop,
        pop_n,
        neg,
        not,
        add,
        sub,
        mul,
        div,
        eql,
        lt,
        gt,
        print,
        dec_glob,
        set_glob,
        get_glob,
        set_locl,
        get_locl,
        jmp,
        jze,
        jnz,
        ret,
        halt,
        call,
    };

    op: Op,
    pld: u24 = undefined,

    pub fn format(
        i: @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (i.op) {
            .const_int,
            .pop_n,
            .dec_glob,
            .set_glob,
            .get_glob,
            .set_locl,
            .get_locl,
            .jmp,
            .jze,
            .jnz,
            .call,
            => try w.print("{t} {d}", .{ i.op, i.pld }),
            else => try w.print("{t}", .{i.op}),
        }
    }
};

pub fn init(w: *std.Io.Writer) Vm {
    return .{ .out = w, .globals = .empty };
}

pub fn deinit(self: *Vm, gpa: std.mem.Allocator) void {
    self.globals.deinit(gpa);
}

const trace_enabled = false;

inline fn trace(op: Inst.Op, pc: usize, stack: []const Value) Inst.Op {
    if (comptime trace_enabled) {
        std.debug.print("{d:>4}: {s:<10} [", .{ pc, @tagName(op) });
        for (stack, 0..) |v, i| {
            if (i != 0) std.debug.print(", ", .{});
            std.debug.print("{f}", .{v});
        }
        std.debug.print("]\n", .{});
    }

    return op;
}

pub fn interpret(vm: *Vm, gpa: std.mem.Allocator, start: usize, insts: []Inst, interner: *Interner, fns: []FnInfo) !void {
    if (insts.len <= 0) return;

    var stack: std.ArrayList(Value) = .empty;
    defer stack.deinit(gpa);

    var call_stack: std.ArrayList(Frame) = .empty;
    defer call_stack.deinit(gpa);

    const next = struct {
        inline fn op(p: *usize, is: []const Inst) Inst.Op {
            p.* += 1;
            return is[p.*].op;
        }
    }.op;

    var pc: usize = start;
    var frame_base: usize = 0;

    loop: switch (insts[pc].op) {
        .nil => {
            try stack.append(gpa, .nil);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .const_int => {
            const v = interner.consts.items[insts[pc].pld];
            try stack.append(gpa, .{ .int = v });
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        inline .neg, .not => |op| {
            try unop(&stack, gpa, op);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        inline .add, .sub, .mul, .div, .eql, .lt, .gt => |op| {
            try binop(&stack, gpa, op);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .dec_glob => {
            const val = stack.pop().?;
            try vm.globals.put(gpa, insts[pc].pld, val);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .get_glob => {
            // add err field to the vm and print the variable that does not exists
            const val = vm.globals.get(insts[pc].pld) orelse return Error.RuntimeError;
            try stack.append(gpa, val);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .set_glob => {
            // add err field to the vm and print the variable that does not exists
            if (!vm.globals.contains(insts[pc].pld)) return Error.RuntimeError;

            const val = stack.pop().?;
            try vm.globals.put(gpa, insts[pc].pld, val);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .get_locl => {
            const v = stack.items[frame_base + insts[pc].pld];
            try stack.append(gpa, v);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .set_locl => {
            const val = stack.pop().?;
            stack.items[frame_base + insts[pc].pld] = val;
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .print => {
            const arg = stack.pop().?;
            try vm.out.print("{f}\n", .{arg});
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .pop => {
            _ = stack.pop().?;
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .pop_n => {
            stack.shrinkRetainingCapacity(stack.items.len - insts[pc].pld);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .jmp => {
            const v = insts[pc].pld;
            pc = v;
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .jze => {
            // TODO: what is going on here? why there is nothing on the stack?
            const cond = stack.pop().?;
            const v = insts[pc].pld;
            pc += 1;
            if (cond == .nil or cond.int == 0) {
                pc = v;
            }
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .jnz => {
            const cond = stack.pop().?;
            const v = insts[pc].pld;
            pc += 1;
            if (cond != .nil and cond.int != 0) {
                pc = v;
            }
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .ret => {
            const res = stack.pop().?;
            stack.shrinkRetainingCapacity(frame_base);
            try stack.append(gpa, res);

            const frame = call_stack.pop().?;
            frame_base = frame.saved_frame_base;
            pc = frame.ret_pc;
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .call => {
            const fn_idx = insts[pc].pld;
            const f = fns[fn_idx];
            try call_stack.append(gpa, .{
                .saved_frame_base = frame_base,
                .ret_pc = pc + 1,
            });

            frame_base = stack.items.len - f.arity;
            pc = f.entry_point;
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .halt => {
            break :loop;
        },
    }
}

inline fn binop(stack: *std.ArrayList(Value), gpa: std.mem.Allocator, comptime op: Inst.Op) !void {
    const b = stack.pop().?;
    const a = stack.pop().?;

    try stack.append(gpa, .{ .int = sw: switch (op) {
        .add => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw a.int + b.int;
        },
        .sub => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw a.int - b.int;
        },
        .mul => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw a.int * b.int;
        },
        .div => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw @divFloor(a.int, b.int);
        },
        .gt => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw if (a.int > b.int) 1 else 0;
        },
        .lt => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw if (a.int < b.int) 1 else 0;
        },
        .eql => {
            if (a == .nil and b == .nil) break :sw 1;
            if (a == .int and b == .int) {
                break :sw if (a.int == b.int) 1 else 0;
            } else {
                return error.EqlWithDifferentTypes;
            }
        },
        else => @compileError("binary op called without an binary operation"),
    } });
}

inline fn unop(stack: *std.ArrayList(Value), gpa: std.mem.Allocator, comptime op: Inst.Op) !void {
    const a = stack.pop().?;
    switch (op) {
        .neg => {
            try stack.append(gpa, if (a == .int) .{ .int = -a.int } else .nil);
        },
        .not => {
            try stack.append(gpa, if (a == .int) .{ .int = 1 - a.int } else .{ .int = 1 });
        },
        else => @compileError("unary op called without an unary operation"),
    }
}
