const std = @import("std");
const Allocator = std.mem.Allocator;
const Interner = @import("Interner.zig");
const builtins = @import("builtins.zig");

const Vm = @This();
const Error = error{RuntimeError};

out: *std.Io.Writer,
globals: std.array_hash_map.Auto(u24, Value),

pub const CallPayload = packed struct(u24) {
    fn_idx: u16,
    arity: u8,
};

pub const FnInfo = struct {
    name_id: u24,
    arity: ?u8,
    body: union(enum) {
        entry: usize,
        native: builtins.NativeFn,
    } = undefined,
};

const StrObj = struct {
    buffer: []const u8,

    pub fn dupe(gpa: Allocator, data: []const u8) !StrObj {
        return .{ .buffer = try gpa.dupe(u8, data) };
    }

    pub fn own(data: []const u8) StrObj {
        return .{ .buffer = data };
    }
};

const ArrayObj = struct {
    elems: std.ArrayList(Value),

    pub fn destroy(s: ArrayObj, gpa: Allocator) void {
        for (s.elems.items) |e| {
            e.destroy(gpa);
        }
        var elems = s.elems;
        elems.deinit(gpa);
    }

    pub fn clone(s: ArrayObj, gpa: Allocator) Allocator.Error!ArrayObj {
        var elems: std.ArrayList(Value) = try .initCapacity(gpa, s.elems.items.len);
        for (s.elems.items) |e| {
            elems.appendAssumeCapacity(try e.clone(gpa));
        }
        return .{ .elems = elems };
    }
};

pub const Value = union(enum) {
    nil,
    int: i64,
    str: StrObj,
    arr: ArrayObj,

    pub fn format(
        v: @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (v) {
            .nil => try w.writeAll("nil"),
            .int => |i| try w.print("{d}", .{i}),
            .str => |s| try w.writeAll(s.buffer),
            .arr => |a| {
                try w.writeByte('[');
                var cnt: u32 = 0;
                for (a.elems.items) |e| {
                    if (cnt > 0) try w.writeAll(", ");
                    cnt += 1;
                    try w.print("{f}", .{e});
                }
                try w.writeByte(']');
            },
        }
    }

    pub inline fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .int => |i| if (i == 0) return false else true,
            else => true,
        };
    }

    pub fn destroy(v: Value, gpa: Allocator) void {
        switch (v) {
            .nil, .int => {},
            .str => |s| {
                gpa.free(s.buffer);
            },
            .arr => |a| {
                a.destroy(gpa);
            },
        }
    }

    pub fn clone(v: Value, gpa: Allocator) Allocator.Error!Value {
        switch (v) {
            .nil, .int => return v,
            .str => |s| {
                return .{ .str = try StrObj.dupe(gpa, s.buffer) };
            },
            .arr => |a| {
                return .{ .arr = try a.clone(gpa) };
            },
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
        str_lit,
        arr_lit,
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
        get_index,
        jmp,
        jmpf,
        jmpt,
        ret,
        halt,
        call,
        call_native,
    };

    op: Op,
    pld: u24 = undefined,

    pub fn format(
        i: @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (i.op) {
            .const_int,
            .str_lit,
            .arr_lit,
            .pop_n,
            .dec_glob,
            .set_glob,
            .get_glob,
            .set_locl,
            .get_locl,
            .jmp,
            .jmpf,
            .jmpt,
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
    for (self.globals.entries.items(.value)) |entry| {
        entry.destroy(gpa);
    }
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
    defer {
        for (stack.items) |*v| {
            v.destroy(gpa);
        }
        stack.deinit(gpa);
    }

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
        .str_lit => {
            const s = interner.strings.items[insts[pc].pld];
            try stack.append(gpa, .{ .str = try .dupe(gpa, s) });
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .arr_lit => {
            const n = insts[pc].pld;
            const src_e = stack.items[stack.items.len - n ..];
            const elems = try gpa.dupe(Value, src_e);
            stack.shrinkRetainingCapacity(stack.items.len - n);

            const arr = ArrayObj{ .elems = .fromOwnedSlice(elems) };
            try stack.append(gpa, .{ .arr = arr });
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
            const id = insts[pc].pld;
            // add err field to the vm and print the variable that does not exists
            if (vm.globals.contains(id)) return Error.RuntimeError;

            const val = stack.pop().?;
            try vm.globals.put(gpa, insts[pc].pld, val);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .get_glob => {
            // add err field to the vm and print the variable that does not exists
            const val = vm.globals.get(insts[pc].pld) orelse return Error.RuntimeError;
            try stack.append(gpa, try val.clone(gpa));
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .set_glob => {
            const id = insts[pc].pld;
            // add err field to the vm and print the variable that does not exists
            if (!vm.globals.contains(id)) return Error.RuntimeError;

            const curr = vm.globals.get(id).?;
            curr.destroy(gpa);

            const val = stack.pop().?;
            try vm.globals.put(gpa, id, val);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .get_locl => {
            const v = stack.items[frame_base + insts[pc].pld];
            try stack.append(gpa, try v.clone(gpa));
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .get_index => {
            try getIdx(&stack, gpa);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .set_locl => {
            const curr = stack.items[frame_base + insts[pc].pld];
            curr.destroy(gpa);

            const val = stack.pop().?;
            stack.items[frame_base + insts[pc].pld] = val;
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .print => {
            const arg = stack.pop().?;
            defer arg.destroy(gpa);
            try vm.out.print("{f}\n", .{arg});
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .pop => {
            const v = stack.pop().?;
            defer v.destroy(gpa);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .pop_n => {
            const elms = stack.items[stack.items.len - insts[pc].pld ..];
            for (elms) |e| {
                e.destroy(gpa);
            }
            stack.shrinkRetainingCapacity(stack.items.len - insts[pc].pld);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .jmp => {
            const v = insts[pc].pld;
            pc = v;
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .jmpf => {
            const val = stack.pop().?;
            defer val.destroy(gpa);
            const target = insts[pc].pld;
            pc += 1;
            if (!val.truthy()) {
                pc = target;
            }
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .jmpt => {
            const val = stack.pop().?;
            defer val.destroy(gpa);
            const target = insts[pc].pld;
            pc += 1;
            if (val.truthy()) {
                pc = target;
            }
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .ret => {
            const res = stack.pop().?;
            const elms = stack.items[frame_base..];
            for (elms) |e| {
                e.destroy(gpa);
            }
            stack.shrinkRetainingCapacity(frame_base);
            try stack.append(gpa, try res.clone(gpa));

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

            frame_base = stack.items.len - f.arity.?;
            pc = f.body.entry;
            continue :loop trace(insts[pc].op, pc, stack.items);
        },
        .call_native => {
            const p: CallPayload = @bitCast(insts[pc].pld);
            const args = stack.items[stack.items.len - p.arity ..];
            const f = fns[p.fn_idx];

            if (f.arity) |arity| {
                if (arity != p.arity) return error.WrongNumbertOfArgs;
            }
            const r = try f.body.native(vm, gpa, args);
            for (args) |a| {
                a.destroy(gpa);
            }
            stack.shrinkRetainingCapacity(stack.items.len - p.arity);
            try stack.append(gpa, r);
            continue :loop trace(next(&pc, insts), pc, stack.items);
        },
        .halt => {
            break :loop;
        },
    }
}

inline fn getIdx(stack: *std.ArrayList(Value), gpa: std.mem.Allocator) !void {
    const idx = stack.pop().?;
    const target = stack.pop().?;
    defer {
        idx.destroy(gpa);
        target.destroy(gpa);
    }

    if (idx != .int) return error.IdxMustBeInt;
    const i = idx.int;
    switch (target) {
        .str => {
            return error.Nyi; // TODO: support chars/bytes?
        },
        .arr => |a| {
            if (i >= a.elems.items.len) return error.IndexOutOfBounds;
            try stack.append(gpa, try a.elems.items[@intCast(i)].clone(gpa));
        },
        else => return error.TargetMustBeIndexable,
    }
}

inline fn binop(stack: *std.ArrayList(Value), gpa: std.mem.Allocator, comptime op: Inst.Op) !void {
    var b = stack.pop().?;
    var a = stack.pop().?;
    defer a.destroy(gpa);
    defer b.destroy(gpa);

    const value: Value = sw: switch (op) {
        .add => {
            if (a == .str and b == .str) {
                const s = try std.fmt.allocPrint(gpa, "{s}{s}", .{ a.str.buffer, b.str.buffer });
                break :sw .{ .str = .own(s) };
            }
            if (a == .arr and b == .arr) {
                try a.arr.elems.appendSlice(gpa, b.arr.elems.items);
                b.arr.elems.clearRetainingCapacity();
                const result = a;
                a = .nil; // take a
                break :sw result;
            }
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw .{ .int = a.int + b.int };
        },
        .sub => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw .{ .int = a.int - b.int };
        },
        .mul => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw .{ .int = a.int * b.int };
        },
        .div => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw .{ .int = @divFloor(a.int, b.int) };
        },
        .gt => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw .{ .int = if (a.int > b.int) 1 else 0 };
        },
        .lt => {
            if (a != .int or b != .int) return error.BinaryOperationNotNums;
            break :sw .{ .int = if (a.int < b.int) 1 else 0 };
        },
        .eql => {
            if (a == .nil and b == .nil) break :sw .{ .int = 1 };
            if (a == .int and b == .int) {
                break :sw .{ .int = if (a.int == b.int) 1 else 0 };
            }
            if (a == .str and b == .str) {
                break :sw .{ .int = if (std.mem.eql(u8, a.str.buffer, b.str.buffer)) 1 else 0 };
            } else {
                return error.EqlWithDifferentTypes;
            }
        },
        else => @compileError("binary op called without an binary operation"),
    };

    try stack.append(gpa, value);
}

inline fn unop(stack: *std.ArrayList(Value), gpa: std.mem.Allocator, comptime op: Inst.Op) !void {
    const a = stack.pop().?;
    defer a.destroy(gpa);
    switch (op) {
        .neg => {
            const r: Value = switch (a) {
                .int => |i| .{ .int = -i },
                else => return error.UnssuportedOpForType,
            };
            try stack.append(gpa, r);
        },
        .not => {
            const t = a.truthy();
            try stack.append(gpa, if (t) .{ .int = 0 } else .{ .int = 1 });
        },
        else => @compileError("unary op called without an unary operation"),
    }
}
