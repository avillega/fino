const std = @import("std");
const Allocator = std.mem.Allocator;
const Interner = @import("Interner.zig");
const builtins = @import("builtins.zig");

const Vm = @This();
const Error = error{RuntimeError};

out: *std.Io.Writer,
globals: std.array_hash_map.Auto(u24, Value),
err: ?[]const u8,

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
    rc: u32,
    buffer: []const u8,
};

const ArrayObj = struct {
    rc: u32,
    elems: std.ArrayList(Value),

    pub fn ensureUnique(arr: *ArrayObj, gpa: Allocator) !*ArrayObj {
        std.debug.assert(arr.rc != 0);
        if (arr.rc == 1) return arr;

        var elems: std.ArrayList(Value) = try .initCapacity(gpa, arr.elems.items.len);
        for (arr.elems.items) |e| {
            elems.appendAssumeCapacity(e.retain());
        }
        const new_arr = try gpa.create(ArrayObj);
        new_arr.* = .{
            .rc = 1,
            .elems = elems,
        };
        arr.rc -= 1;
        return new_arr;
    }
};

pub const Value = union(enum) {
    nil,
    taken,
    int: i64,
    str: *StrObj,
    arr: *ArrayObj,

    pub fn format(
        v: @This(),
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (v) {
            .nil => try w.writeAll("nil"),
            .taken => try w.writeAll("<taken>"),
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
            .taken => unreachable,
            .nil => false,
            .int => |i| if (i == 0) return false else true,
            else => true,
        };
    }

    pub fn release(v: Value, gpa: Allocator) void {
        switch (v) {
            .nil, .int, .taken => {},
            .str => |s| {
                s.rc -= 1;
                if (s.rc == 0) {
                    gpa.free(s.buffer);
                    gpa.destroy(s);
                }
            },
            .arr => |a| {
                a.rc -= 1;
                if (a.rc == 0) {
                    for (a.elems.items) |e| {
                        e.release(gpa);
                    }
                    a.elems.deinit(gpa);
                    gpa.destroy(a);
                }
            },
        }
    }

    pub fn retain(v: Value) Value {
        switch (v) {
            .nil, .int, .taken => {},
            .str => |s| {
                std.debug.assert(s.rc != 0);
                s.rc += 1;
            },
            .arr => |a| {
                std.debug.assert(a.rc != 0);
                a.rc += 1;
            },
        }
        return v;
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
        put_glob, // sibling of set_glob to be used when take_glob is used
        get_glob,
        take_glob,
        set_locl,
        get_locl,
        take_locl,
        get_index,
        set_index,
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

    pub fn debugPrint(
        i: @This(),
        w: *std.Io.Writer,
        vm: Vm,
        interner: Interner,
    ) std.Io.Writer.Error!void {
        switch (i.op) {
            .const_int => try w.print("{t} {d}", .{ i.op, interner.consts.items[i.pld] }),
            .str_lit => try w.print("{t} {s}", .{ i.op, interner.strings.items[i.pld] }),
            .dec_glob => try w.print("{t} {s}", .{ i.op, interner.strings.items[i.pld] }),
            .set_glob,
            .put_glob,
            .get_glob,
            .take_glob,
            => try w.print("{t} {f}", .{ i.op, vm.globals.get(i.pld).? }),
            .set_locl,
            .get_locl,
            .take_locl,
            .arr_lit,
            .pop_n,
            .jmp,
            .jmpf,
            .jmpt,
            .call,
            => try w.print("{t} {d}", .{ i.op, i.pld }),
            else => try w.print("{t}", .{i.op}),
        }
    }

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
            .put_glob,
            .get_glob,
            .set_locl,
            .get_locl,
            .take_locl,
            .take_glob,
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
    return .{ .out = w, .globals = .empty, .err = null };
}

pub fn deinit(self: *Vm, gpa: std.mem.Allocator) void {
    for (self.globals.entries.items(.value)) |entry| {
        entry.release(gpa);
    }
    self.globals.deinit(gpa);
}

const trace_enabled = false;

inline fn trace(inst: Inst, pc: usize, vm: *Vm, interner: *Interner, stack: []const Value) Inst.Op {
    if (comptime trace_enabled) {
        var buf: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        inst.debugPrint(&writer, vm.*, interner.*) catch {};

        const inst_str = buf[0..writer.end];
        std.debug.print("{d:>4}: {s:<10} [", .{ pc, inst_str });
        for (stack, 0..) |v, i| {
            if (i != 0) std.debug.print(", ", .{});
            std.debug.print("{f}", .{v});
        }
        std.debug.print("]\n", .{});
    }

    return inst.op;
}

pub fn interpret(vm: *Vm, gpa: std.mem.Allocator, start: usize, insts: []Inst, interner: *Interner, fns: []FnInfo) !void {
    if (insts.len <= 0) return;

    var stack: std.ArrayList(Value) = .empty;
    defer {
        for (stack.items) |*v| {
            v.release(gpa);
        }
        stack.deinit(gpa);
    }

    var call_stack: std.ArrayList(Frame) = .empty;
    defer call_stack.deinit(gpa);

    const next = struct {
        inline fn op(p: *usize, is: []const Inst) Inst {
            p.* += 1;
            return is[p.*];
        }
    }.op;

    var pc: usize = start;
    var frame_base: usize = 0;

    loop: switch (trace(insts[pc], pc, vm, interner, stack.items)) {
        .nil => {
            try stack.append(gpa, .nil);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .const_int => {
            const v = interner.consts.items[insts[pc].pld];
            try stack.append(gpa, .{ .int = v });
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .str_lit => {
            const s = interner.strings.items[insts[pc].pld];
            const str = try gpa.create(StrObj);
            str.* = .{
                .rc = 1,
                .buffer = try gpa.dupe(u8, s),
            };
            try stack.append(gpa, .{ .str = str });
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .arr_lit => {
            const n = insts[pc].pld;
            const src_e = stack.items[stack.items.len - n ..];
            const elems = try gpa.dupe(Value, src_e);
            stack.shrinkRetainingCapacity(stack.items.len - n);
            const arr = try gpa.create(ArrayObj);
            arr.* = ArrayObj{ .rc = 1, .elems = .fromOwnedSlice(elems) };
            try stack.append(gpa, .{ .arr = arr });
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        inline .neg, .not => |op| {
            try unop(&stack, gpa, op);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        inline .add, .sub, .mul, .div, .eql, .lt, .gt => |op| {
            try binop(&stack, gpa, op);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .dec_glob => {
            const id = insts[pc].pld;
            if (vm.globals.contains(id)) {
                vm.err = try std.fmt.allocPrint(
                    gpa,
                    "error: Gloabal redeclaration {s}",
                    .{interner.get_s(id) catch "unknown"},
                );
                return Error.RuntimeError;
            }

            const val = stack.pop().?;
            try vm.globals.put(gpa, insts[pc].pld, val);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .get_glob => {
            // add err field to the vm and print the variable that does not exists
            const val = vm.globals.get(insts[pc].pld) orelse return Error.RuntimeError;
            if (val == .taken) {
                vm.err = try std.fmt.allocPrint(
                    gpa,
                    "global {s} was moved and can not be used\n",
                    .{try interner.get_s(insts[pc].pld)},
                );
                return error.RuntimeError;
            }
            try stack.append(gpa, val.retain());
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .take_glob => {
            const val = vm.globals.getPtr(insts[pc].pld) orelse return Error.RuntimeError;
            if (val.* == .taken) {
                vm.err = try std.fmt.allocPrint(
                    gpa,
                    "global {s} was moved and can not be used\n",
                    .{try interner.get_s(insts[pc].pld)},
                );
                return error.RuntimeError;
            }
            try stack.append(gpa, val.*);
            val.* = .taken;
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .set_glob => {
            const id = insts[pc].pld;
            const old = vm.globals.getPtr(id) orelse {
                vm.err = try std.fmt.allocPrint(
                    gpa,
                    "global {s} does not exists\n",
                    .{try interner.get_s(insts[pc].pld)},
                );
                return Error.RuntimeError;
            };

            if (old.* == .taken) {
                vm.err = try std.fmt.allocPrint(
                    gpa,
                    "attempting to write back to taken global {s}\n",
                    .{try interner.get_s(insts[pc].pld)},
                );
                return Error.RuntimeError;
            }

            old.release(gpa);

            const val = stack.pop().?;
            old.* = val;
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .put_glob => {
            const id = insts[pc].pld;
            const old = vm.globals.getPtr(id) orelse {
                vm.err = try std.fmt.allocPrint(
                    gpa,
                    "global {s} does not exists\n",
                    .{try interner.get_s(insts[pc].pld)},
                );
                return Error.RuntimeError;
            };

            std.debug.assert(old.* == .taken);
            const val = stack.pop().?;
            old.* = val;
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .get_locl => {
            const v = stack.items[frame_base + insts[pc].pld];
            std.debug.assert(v != .taken);
            try stack.append(gpa, v.retain());
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .take_locl => {
            const v = stack.items[frame_base + insts[pc].pld];
            std.debug.assert(v != .taken);

            stack.items[frame_base + insts[pc].pld] = .taken;
            try stack.append(gpa, v);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .get_index => {
            try getIdx(&stack, gpa);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .set_index => {
            try setIdx(&stack, gpa);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .set_locl => {
            const curr = stack.items[frame_base + insts[pc].pld];
            curr.release(gpa);

            const val = stack.pop().?;
            stack.items[frame_base + insts[pc].pld] = val;
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .print => {
            const arg = stack.pop().?;
            defer arg.release(gpa);
            try vm.out.print("{f}\n", .{arg});
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .pop => {
            const v = stack.pop().?;
            defer v.release(gpa);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .pop_n => {
            const elms = stack.items[stack.items.len - insts[pc].pld ..];
            for (elms) |e| {
                e.release(gpa);
            }
            stack.shrinkRetainingCapacity(stack.items.len - insts[pc].pld);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
        },
        .jmp => {
            const v = insts[pc].pld;
            pc = v;
            continue :loop trace(insts[pc], pc, vm, interner, stack.items);
        },
        .jmpf => {
            const val = stack.pop().?;
            defer val.release(gpa);
            const target = insts[pc].pld;
            pc += 1;
            if (!val.truthy()) {
                pc = target;
            }
            continue :loop trace(insts[pc], pc, vm, interner, stack.items);
        },
        .jmpt => {
            const val = stack.pop().?;
            defer val.release(gpa);
            const target = insts[pc].pld;
            pc += 1;
            if (val.truthy()) {
                pc = target;
            }
            continue :loop trace(insts[pc], pc, vm, interner, stack.items);
        },
        .ret => {
            const res = stack.pop().?;
            const elms = stack.items[frame_base..];
            for (elms) |e| {
                e.release(gpa);
            }
            stack.shrinkRetainingCapacity(frame_base);
            try stack.append(gpa, res);

            const frame = call_stack.pop().?;
            frame_base = frame.saved_frame_base;
            pc = frame.ret_pc;
            continue :loop trace(insts[pc], pc, vm, interner, stack.items);
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
            continue :loop trace(insts[pc], pc, vm, interner, stack.items);
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
                a.release(gpa);
            }
            stack.shrinkRetainingCapacity(stack.items.len - p.arity);
            try stack.append(gpa, r);
            continue :loop trace(next(&pc, insts), pc, vm, interner, stack.items);
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
        idx.release(gpa);
        target.release(gpa);
    }

    if (idx != .int) return error.IdxMustBeInt;
    const i = idx.int;
    switch (target) {
        .str => {
            return error.Nyi; // TODO: support chars/bytes?
        },
        .arr => |a| {
            if (i < 0 or i >= a.elems.items.len) return error.IndexOutOfBounds;
            try stack.append(gpa, a.elems.items[@intCast(i)].retain());
        },
        else => return error.TargetMustBeIndexable,
    }
}

inline fn setIdx(stack: *std.ArrayList(Value), gpa: std.mem.Allocator) !void {
    const arr = stack.pop().?;
    const val = stack.pop().?;
    const idx = stack.pop().?;
    defer {
        idx.release(gpa);
    }
    errdefer {
        arr.release(gpa);
        val.release(gpa);
    }

    if (arr != .arr) return error.TargetMustBeIndexable;
    if (idx != .int) return error.IdxMustBeInt;
    if (idx.int < 0 or idx.int >= arr.arr.elems.items.len) return error.IndexOutOfBounds;

    var x = try arr.arr.ensureUnique(gpa);
    x.elems.items[@bitCast(idx.int)].release(gpa);
    x.elems.items[@bitCast(idx.int)] = val;
    try stack.append(gpa, .{ .arr = x });
}

inline fn binop(stack: *std.ArrayList(Value), gpa: std.mem.Allocator, comptime op: Inst.Op) !void {
    var b = stack.pop().?;
    var a = stack.pop().?;
    defer a.release(gpa);
    defer b.release(gpa);

    const value: Value = sw: switch (op) {
        .add => {
            if (a == .str and b == .str) {
                const s = try std.fmt.allocPrint(gpa, "{s}{s}", .{ a.str.buffer, b.str.buffer });
                const str = try gpa.create(StrObj);
                str.* = .{
                    .rc = 1,
                    .buffer = s,
                };
                break :sw .{ .str = str };
            }
            if (a == .arr and b == .arr) {
                // take a
                const x = try a.arr.ensureUnique(gpa);
                a = .nil;

                try x.elems.ensureUnusedCapacity(gpa, b.arr.elems.items.len);
                for (b.arr.elems.items) |e| {
                    x.elems.appendAssumeCapacity(e.retain());
                }
                break :sw .{ .arr = x };
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
    defer a.release(gpa);
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
