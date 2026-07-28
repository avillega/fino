const std = @import("std");
const Allocator = std.mem.Allocator;
const Interner = @import("Interner.zig");
const builtins = @import("builtins.zig");

const Vm = @This();
const Error = error{RuntimeError} || Allocator.Error;

pub const CallPayload = packed struct(u24) {
    fn_idx: u16,
    arity: u8,
};

pub const IterPayload = packed struct(u24) {
    n: u4,
    exit: u20,
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

const RecordObj = struct {
    rc: u32,
    map: std.array_hash_map.Auto(u24, Value),

    pub fn ensureUnique(r: *RecordObj, gpa: Allocator) !*RecordObj {
        std.debug.assert(r.rc != 0);
        if (r.rc == 1) return r;

        for (r.map.values()) |v| {
            _ = v.retain();
        }

        const map: std.array_hash_map.Auto(u24, Value) = try .init(
            gpa,
            r.map.keys(),
            r.map.values(),
        );
        const new_r = try gpa.create(RecordObj);
        new_r.* = .{
            .rc = 1,
            .map = map,
        };
        r.rc -= 1;
        return new_r;
    }
};

pub const Value = union(enum) {
    nil,
    taken,
    int: i64,
    atom: u24,
    str: *StrObj,
    arr: *ArrayObj,
    rec: *RecordObj,

    pub fn fmt(v: Value, interner: *const Interner) FmtValue {
        return .{ .v = v, .interner = interner };
    }

    pub const FmtValue = struct {
        v: Value,
        interner: *const Interner,

        pub fn format(
            self: @This(),
            w: *std.Io.Writer,
        ) std.Io.Writer.Error!void {
            switch (self.v) {
                .nil => try w.writeAll("nil"),
                .taken => try w.writeAll("<taken>"),
                .int => |i| try w.print("{d}", .{i}),
                .atom => |id| try w.print(":{s}", .{self.interner.get_s(id) catch "?"}),
                .str => |s| try w.writeAll(s.buffer),
                .arr => |a| {
                    try w.writeByte('[');
                    for (a.elems.items, 0..) |e, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.print("{f}", .{e.fmt(self.interner)});
                    }
                    try w.writeByte(']');
                },
                .rec => |r| {
                    try w.writeAll(".{");
                    for (r.map.keys(), r.map.values(), 0..) |k, e, i| {
                        if (i > 0) try w.writeAll(", ");
                        try w.print(":{s} {f}", .{
                            self.interner.get_s(k) catch "?",
                            e.fmt(self.interner),
                        });
                    }
                    try w.writeByte('}');
                },
            }
        }
    };

    pub inline fn truthy(v: Value) bool {
        return switch (v) {
            .taken => unreachable,
            .nil => false,
            .int => |i| i != 0,
            else => true,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .taken => unreachable,
            .nil => true,
            .int => a.int == b.int,
            .atom => a.atom == b.atom,
            .str => |s| s == b.str or std.mem.eql(u8, s.buffer, b.str.buffer),
            .arr => |x| {
                const y = b.arr;
                if (x == y) return true;
                if (x.elems.items.len != y.elems.items.len) return false;
                for (x.elems.items, y.elems.items) |i, j| {
                    if (!i.eql(j)) return false;
                }
                return true;
            },
            .rec => |x| {
                const y = b.rec;
                if (x == y) return true;
                if (x.map.count() != y.map.count()) return false;
                for (x.map.keys(), x.map.values()) |k, v| {
                    const other = y.map.get(k) orelse return false;
                    if (!v.eql(other)) return false;
                }
                return true;
            },
        };
    }

    pub fn release(v: Value, gpa: Allocator) void {
        switch (v) {
            .nil, .int, .taken, .atom => {},
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
            .rec => |r| {
                r.rc -= 1;
                if (r.rc == 0) {
                    for (r.map.values()) |e| {
                        e.release(gpa);
                    }
                    r.map.deinit(gpa);
                    gpa.destroy(r);
                }
            },
        }
    }

    pub fn retain(v: Value) Value {
        switch (v) {
            .nil, .int, .taken, .atom => {},
            inline .str, .arr, .rec => |o| {
                std.debug.assert(o.rc != 0);
                o.rc += 1;
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
        atom,
        str_lit,
        arr_lit,
        record_lit,
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
        iter_begin,
        iter_next,
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
    ) std.Io.Writer.Error!void {
        switch (i.op) {
            .const_int => try w.print("{t} {d}", .{ i.op, vm.interner.consts.items[i.pld] }),
            .str_lit => try w.print("{t} \"{s}\"", .{ i.op, vm.interner.strings.items[i.pld] }),
            .atom => try w.print("{t} :{s}", .{ i.op, vm.interner.strings.items[i.pld] }),
            .dec_glob => try w.print("{t} {s}", .{ i.op, vm.interner.strings.items[i.pld] }),
            .set_glob,
            .put_glob,
            .get_glob,
            .take_glob,
            => try w.print("{t} {f}", .{ i.op, vm.globals.get(i.pld).?.fmt(vm.interner) }),
            .set_locl,
            .get_locl,
            .take_locl,
            .arr_lit,
            .record_lit,
            .pop_n,
            .jmp,
            .jmpf,
            .jmpt,
            .call,
            => try w.print("{t} {d}", .{ i.op, i.pld }),
            .call_native => {
                const p: CallPayload = @bitCast(i.pld);
                try w.print("{t} {d}/{d}", .{ i.op, p.fn_idx, p.arity });
            },
            .iter_next => {
                const p: IterPayload = @bitCast(i.pld);
                try w.print("{t} {d}", .{ i.op, p.exit });
            },
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

out: *std.Io.Writer,
gpa: Allocator,
interner: *const Interner,
globals: std.array_hash_map.Auto(u24, Value),
stack: std.ArrayList(Value),
err: ?[]const u8,

pub fn init(w: *std.Io.Writer, gpa: Allocator, interner: *const Interner) Vm {
    return .{
        .out = w,
        .interner = interner,
        .gpa = gpa,
        .stack = .empty,
        .globals = .empty,
        .err = null,
    };
}

pub fn deinit(self: *Vm) void {
    for (self.stack.items) |*v| {
        v.release(self.gpa);
    }
    self.stack.deinit(self.gpa);
    for (self.globals.values()) |value| {
        value.release(self.gpa);
    }
    self.globals.deinit(self.gpa);
    if (self.err) |err| self.gpa.free(err);
}

fn fail(vm: *Vm, comptime format: []const u8, args: anytype) Error {
    vm.err = try std.fmt.allocPrint(vm.gpa, format, args);
    return Error.RuntimeError;
}

fn nameOf(vm: *Vm, id: u24) []const u8 {
    return vm.interner.get_s(id) catch "?";
}

const trace_enabled = false;

inline fn trace(vm: *Vm, inst: Inst, pc: usize) Inst.Op {
    if (comptime trace_enabled) {
        var buf: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        inst.debugPrint(&writer, vm.*) catch {};

        const inst_str = buf[0..writer.end];
        std.debug.print("{d:>4}: {s:<10} [", .{ pc, inst_str });
        for (vm.stack.items, 0..) |v, i| {
            if (i != 0) std.debug.print(", ", .{});
            std.debug.print("{f}", .{v.fmt(vm.interner)});
        }
        std.debug.print("]\n", .{});
    }

    return inst.op;
}

pub fn interpret(vm: *Vm, start: usize, insts: []Inst, fns: []FnInfo) !void {
    if (insts.len <= 0) return;

    var call_stack: std.ArrayList(Frame) = .empty;
    defer call_stack.deinit(vm.gpa);

    const next = struct {
        inline fn op(p: *usize, is: []const Inst) Inst {
            p.* += 1;
            return is[p.*];
        }
    }.op;

    var pc: usize = start;
    var frame_base: usize = 0;

    loop: switch (vm.trace(insts[pc], pc)) {
        .nil => {
            try vm.stack.append(vm.gpa, .nil);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .const_int => {
            const v = vm.interner.consts.items[insts[pc].pld];
            try vm.stack.append(vm.gpa, .{ .int = v });
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .atom => {
            try vm.stack.append(vm.gpa, .{ .atom = insts[pc].pld });
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .str_lit => {
            const s = vm.interner.strings.items[insts[pc].pld];
            const str = try vm.gpa.create(StrObj);
            str.* = .{
                .rc = 1,
                .buffer = try vm.gpa.dupe(u8, s),
            };
            try vm.stack.append(vm.gpa, .{ .str = str });
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .arr_lit => {
            const n = insts[pc].pld;
            const src_e = vm.stack.items[vm.stack.items.len - n ..];
            const elems = try vm.gpa.dupe(Value, src_e);
            vm.stack.shrinkRetainingCapacity(vm.stack.items.len - n);
            const arr = try vm.gpa.create(ArrayObj);
            arr.* = ArrayObj{ .rc = 1, .elems = .fromOwnedSlice(elems) };
            try vm.stack.append(vm.gpa, .{ .arr = arr });
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .record_lit => {
            const pairs = insts[pc].pld;
            const src_e = vm.stack.items[vm.stack.items.len - (2 * pairs) ..];

            const rec = try vm.gpa.create(RecordObj);
            rec.* = RecordObj{ .rc = 1, .map = .empty };
            try rec.map.ensureTotalCapacity(vm.gpa, pairs);
            for (0..pairs) |i| {
                const ki = i * 2;
                const vi = (i * 2) + 1;
                const k = src_e[ki];
                std.debug.assert(k == .atom);
                rec.map.putAssumeCapacity(k.atom, src_e[vi]);
            }
            vm.stack.shrinkRetainingCapacity(vm.stack.items.len - (2 * pairs));
            try vm.stack.append(vm.gpa, .{ .rec = rec });
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        inline .neg, .not => |op| {
            try vm.unop(op);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        inline .add, .sub, .mul, .div, .eql, .lt, .gt => |op| {
            try vm.binop(op);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .dec_glob => {
            const id = insts[pc].pld;
            if (vm.globals.contains(id)) {
                return vm.fail("global redeclaration {s}", .{vm.nameOf(id)});
            }

            const val = vm.stack.pop().?;
            try vm.globals.put(vm.gpa, insts[pc].pld, val);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .get_glob => {
            const val = vm.globals.get(insts[pc].pld) orelse return Error.RuntimeError;
            if (val == .taken) {
                return vm.fail("global {s} was moved and can not be used", .{vm.nameOf(insts[pc].pld)});
            }
            try vm.stack.append(vm.gpa, val.retain());
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .take_glob => {
            const val = vm.globals.getPtr(insts[pc].pld) orelse return Error.RuntimeError;
            if (val.* == .taken) {
                return vm.fail("global {s} was moved and can not be used", .{vm.nameOf(insts[pc].pld)});
            }
            try vm.stack.append(vm.gpa, val.*);
            val.* = .taken;
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .set_glob => {
            const id = insts[pc].pld;
            const old = vm.globals.getPtr(id) orelse
                return vm.fail("global {s} does not exist", .{vm.nameOf(id)});

            if (old.* == .taken) {
                return vm.fail("attempting to write back to taken global {s}", .{vm.nameOf(id)});
            }

            old.release(vm.gpa);

            const val = vm.stack.pop().?;
            old.* = val;
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .put_glob => {
            const id = insts[pc].pld;
            const old = vm.globals.getPtr(id) orelse
                return vm.fail("global {s} does not exist", .{vm.nameOf(id)});

            std.debug.assert(old.* == .taken);
            const val = vm.stack.pop().?;
            old.* = val;
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .get_locl => {
            const v = vm.stack.items[frame_base + insts[pc].pld];
            std.debug.assert(v != .taken);
            try vm.stack.append(vm.gpa, v.retain());
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .take_locl => {
            const v = vm.stack.items[frame_base + insts[pc].pld];
            std.debug.assert(v != .taken);

            vm.stack.items[frame_base + insts[pc].pld] = .taken;
            try vm.stack.append(vm.gpa, v);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .get_index => {
            try vm.getIdx();
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .set_index => {
            try vm.setIdx();
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .set_locl => {
            const curr = vm.stack.items[frame_base + insts[pc].pld];
            curr.release(vm.gpa);

            const val = vm.stack.pop().?;
            vm.stack.items[frame_base + insts[pc].pld] = val;
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .print => {
            const arg = vm.stack.pop().?;
            defer arg.release(vm.gpa);
            try vm.out.print("{f}\n", .{arg.fmt(vm.interner)});
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .pop => {
            const v = vm.stack.pop().?;
            defer v.release(vm.gpa);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .pop_n => {
            const elms = vm.stack.items[vm.stack.items.len - insts[pc].pld ..];
            for (elms) |e| {
                e.release(vm.gpa);
            }
            vm.stack.shrinkRetainingCapacity(vm.stack.items.len - insts[pc].pld);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .jmp => {
            const v = insts[pc].pld;
            pc = v;
            continue :loop vm.trace(insts[pc], pc);
        },
        .jmpf => {
            const val = vm.stack.pop().?;
            defer val.release(vm.gpa);
            const target = insts[pc].pld;
            pc += 1;
            if (!val.truthy()) {
                pc = target;
            }
            continue :loop vm.trace(insts[pc], pc);
        },
        .jmpt => {
            const val = vm.stack.pop().?;
            defer val.release(vm.gpa);
            const target = insts[pc].pld;
            pc += 1;
            if (val.truthy()) {
                pc = target;
            }
            continue :loop vm.trace(insts[pc], pc);
        },
        .ret => {
            const res = vm.stack.pop().?;
            const elms = vm.stack.items[frame_base..];
            for (elms) |e| {
                e.release(vm.gpa);
            }
            vm.stack.shrinkRetainingCapacity(frame_base);
            try vm.stack.append(vm.gpa, res);

            const frame = call_stack.pop().?;
            frame_base = frame.saved_frame_base;
            pc = frame.ret_pc;
            continue :loop vm.trace(insts[pc], pc);
        },
        .call => {
            const fn_idx = insts[pc].pld;
            const f = fns[fn_idx];
            try call_stack.append(vm.gpa, .{
                .saved_frame_base = frame_base,
                .ret_pc = pc + 1,
            });

            frame_base = vm.stack.items.len - f.arity.?;
            pc = f.body.entry;
            continue :loop vm.trace(insts[pc], pc);
        },
        .call_native => {
            const p: CallPayload = @bitCast(insts[pc].pld);
            const args = vm.stack.items[vm.stack.items.len - p.arity ..];
            const f = fns[p.fn_idx];

            if (f.arity) |arity| {
                if (arity != p.arity) return error.WrongNumbertOfArgs;
            }
            const r = try f.body.native(vm, args);
            for (args) |a| {
                a.release(vm.gpa);
            }
            vm.stack.shrinkRetainingCapacity(vm.stack.items.len - p.arity);
            try vm.stack.append(vm.gpa, r);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .iter_begin => {
            const n = insts[pc].pld;
            const it = vm.stack.items[vm.stack.items.len - 1];
            switch (it) {
                .arr, .rec => {},
                else => return vm.fail("cannot iterate over {f}", .{it.fmt(vm.interner)}),
            }
            try vm.stack.append(vm.gpa, .{ .int = 0 });
            try vm.stack.appendNTimes(vm.gpa, .nil, n);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .iter_next => {
            const p: IterPayload = @bitCast(insts[pc].pld);
            const it = vm.stack.items[vm.stack.items.len - p.n - 2];
            const cur = &vm.stack.items[vm.stack.items.len - p.n - 1];
            const i = cur.int; // must be int

            const count = switch (it) {
                .arr => |a| a.elems.items.len,
                .rec => |r| r.map.count(),
                else => unreachable,
            };

            if (i >= count) {
                pc = p.exit;
                continue :loop vm.trace(insts[pc], pc);
            }
            cur.int += 1;

            const capts = vm.stack.items[vm.stack.items.len - p.n ..];
            switch (p.n) {
                1 => {
                    const v = switch (it) {
                        .arr => |arr| arr.elems.items[@bitCast(i)],
                        .rec => |rec| rec.map.values()[@bitCast(i)],
                        else => unreachable,
                    };
                    capts[0].release(vm.gpa);
                    capts[0] = v.retain();
                },
                2 => {
                    const k: Value, const v: Value = switch (it) {
                        .arr => |arr| .{ .{ .int = i }, arr.elems.items[@bitCast(i)] },
                        .rec => |rec| .{ .{ .atom = rec.map.keys()[@bitCast(i)] }, rec.map.values()[@bitCast(i)] },
                        else => unreachable,
                    };
                    capts[0].release(vm.gpa);
                    capts[0] = k.retain();
                    capts[1].release(vm.gpa);
                    capts[1] = v.retain();
                },
                else => unreachable,
            }
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .halt => {
            break :loop;
        },
    }
}

inline fn getIdx(vm: *Vm) !void {
    const idx = vm.stack.pop().?;
    const target = vm.stack.pop().?;
    defer {
        idx.release(vm.gpa);
        target.release(vm.gpa);
    }

    switch (target) {
        .str => return error.Nyi, // TODO: support chars/bytes?
        .arr => |a| {
            if (idx != .int) return error.IdxMustBeInt;

            const i = idx.int;
            if (i < 0 or i >= a.elems.items.len) return error.IndexOutOfBounds;
            try vm.stack.append(vm.gpa, a.elems.items[@intCast(i)].retain());
        },
        .rec => |r| {
            if (idx != .atom) return error.IdxMustBeAtom;
            const v: Value = r.map.get(idx.atom) orelse .nil;
            try vm.stack.append(vm.gpa, v.retain());
        },
        else => return error.TargetMustBeIndexable,
    }
}

inline fn setIdx(vm: *Vm) !void {
    const target = vm.stack.pop().?;
    const val = vm.stack.pop().?;
    const idx = vm.stack.pop().?;
    defer {
        idx.release(vm.gpa);
    }
    errdefer {
        target.release(vm.gpa);
        val.release(vm.gpa);
    }

    switch (target) {
        .arr => |a| {
            if (idx != .int) return error.IdxMustBeInt;
            if (idx.int < 0 or idx.int >= a.elems.items.len) return error.IndexOutOfBounds;
            const i: usize = @intCast(idx.int);

            const x = try a.ensureUnique(vm.gpa);
            x.elems.items[i].release(vm.gpa);
            x.elems.items[i] = val;
            try vm.stack.append(vm.gpa, .{ .arr = x });
        },
        .rec => |r| {
            if (idx != .atom) return error.IdxMustBeAtom;
            const x = try r.ensureUnique(vm.gpa);

            const gop = try x.map.getOrPut(vm.gpa, idx.atom);
            if (gop.found_existing) {
                gop.value_ptr.*.release(vm.gpa);
            }
            gop.value_ptr.* = val;
            try vm.stack.append(vm.gpa, .{ .rec = x });
        },
        else => return error.TargetMustBeIndexable,
    }
}

inline fn binop(vm: *Vm, comptime op: Inst.Op) !void {
    var b = vm.stack.pop().?;
    var a = vm.stack.pop().?;
    defer a.release(vm.gpa);
    defer b.release(vm.gpa);

    if (a == .int and b == .int) {
        const r: i64 = switch (op) {
            .add => a.int + b.int,
            .sub => a.int - b.int,
            .mul => a.int * b.int,
            .div => @divFloor(a.int, b.int),
            .eql => @intFromBool(a.int == b.int),
            .lt => @intFromBool(a.int < b.int),
            .gt => @intFromBool(a.int > b.int),
            else => @compileError("binary op called without an binary operation"),
        };
        return vm.stack.append(vm.gpa, .{ .int = r });
    }

    const value: Value = switch (op) {
        .add => blk: {
            if (a == .str and b == .str) {
                const s = try std.fmt.allocPrint(vm.gpa, "{s}{s}", .{ a.str.buffer, b.str.buffer });
                const str = try vm.gpa.create(StrObj);
                str.* = .{
                    .rc = 1,
                    .buffer = s,
                };
                break :blk .{ .str = str };
            }
            if (a == .arr and b == .arr) {
                // take a
                const x = try a.arr.ensureUnique(vm.gpa);
                a = .nil;

                try x.elems.ensureUnusedCapacity(vm.gpa, b.arr.elems.items.len);
                for (b.arr.elems.items) |e| {
                    x.elems.appendAssumeCapacity(e.retain());
                }
                break :blk .{ .arr = x };
            }
            return error.CanNotAdd;
        },
        .eql => .{ .int = @intFromBool(a.eql(b)) },
        else => return error.IllegalBinaryOperation,
    };

    try vm.stack.append(vm.gpa, value);
}

inline fn unop(vm: *Vm, comptime op: Inst.Op) !void {
    const a = vm.stack.pop().?;
    defer a.release(vm.gpa);
    switch (op) {
        .neg => {
            const r: Value = switch (a) {
                .int => |i| .{ .int = -i },
                else => return error.UnssuportedOpForType,
            };
            try vm.stack.append(vm.gpa, r);
        },
        .not => {
            try vm.stack.append(vm.gpa, .{ .int = @intFromBool(!a.truthy()) });
        },
        else => @compileError("unary op called without an unary operation"),
    }
}
