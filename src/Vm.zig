const std = @import("std");
const builtin = @import("builtin");
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
    max_reg: u8,
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
    idx: usize,
    number: f64,
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
                .idx => try w.writeAll("<idx>"),
                .number => |i| try w.print("{d}", .{i}),
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
            .number => |i| i != 0,
            else => true,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .taken => unreachable,
            .nil => true,
            .idx => a.idx == b.idx,
            .number => a.number == b.number,
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
            .nil,
            .number,
            .taken,
            .atom,
            .idx,
            => {},
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
            .nil, .number, .taken, .atom, .idx => {},
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
    saved_frame_len: usize,
};

pub const Inst = packed struct(u32) {
    pub const Op = enum(u8) {
        lnil,
        lnum,
        latm,
        lstr,
        copy,
        move,
        add,
        sub,
        mul,
        div,
        mod,
        not,
        eql,
        neq,
        ltn,
        leq,
        jmp,
        jmf,
        jmt,
        getg,
        setg,
        takg,
        putg,
        arr,
        rec,
        geti,
        seti,
        call,
        calln,
        ret,
        iter_begin,
        iter_next1,
        iter_next2,
        release,
        halt,

        pub fn form(op: Op) Form {
            switch (op) {
                .copy, .move, .add, .sub, .mul, .div, .mod, .not, .eql, .neq, .ltn, .leq, .arr, .rec, .geti, .seti, .calln, .ret, .iter_begin, .release, .halt => .abc,
                .lnil, .lnum, .latm, .lstr, .getg, .setg, .takg, .putg, .call => .abx,
                .jmp, .jmf, .jmt, .iter_next1, .iter_next2 => .sbx,
            }
        }
    };

    pub const Form = enum { abc, abx, sbx };
    pub const Payload = packed union {
        abc: packed struct(u24) { a: u8, b: u8, c: u8 },
        abx: packed struct(u24) { a: u8, b: u16 },
        sbx: packed struct(u24) { a: u8, sbx: i16 },
    };

    op: Op,
    pld: Payload,

    pub fn make(comptime op: Op, args: @FieldType(Payload, @tagName(op.form()))) Inst {
        return .{ .op = op, .pld = args };
    }

    pub fn as(inst: Inst, comptime form: Form) @FieldType(Payload, @tagName(form)) {
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            std.debug.assert(inst.op.form() == form);
        }
        return @field(inst.pld, @tagName(form));
    }
};

out: *std.Io.Writer,
gpa: Allocator,
interner: *const Interner,
globals: std.array_hash_map.Auto(u24, Value),
regs: std.ArrayList(Value),
err: ?[]const u8,

pub fn init(w: *std.Io.Writer, gpa: Allocator, interner: *const Interner) Vm {
    return .{
        .out = w,
        .interner = interner,
        .gpa = gpa,
        .regs = .empty,
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

    const Ip = struct {
        vm: *Vm,
        pc: usize,
        _insts: []Inst,
        inline fn inst(ip: *@This()) Inst {
            return ip._insts[ip.pc];
        }
        inline fn next(ip: *@This()) Inst {
            ip.pc += 1;
            return vm.trace(ip._insts[ip.pc], ip.pc);
        }
        inline fn goto(ip: *@This(), sbx: i16) Inst {
            ip.pc += sbx;
            return vm.trace(ip._insts[ip.pc], ip.pc);
        }
    };

    var frame_base: usize = 0;
    var r: []Value = &.{};
    const ip: Ip = .{ .vm = vm, .pc = start, ._insts = insts };

    loop: switch (vm.trace(ip.inst(), start)) {
        .lnil => {
            const p = ip.inst().as(.abc);
            vm.store(p.a, .nil);
            continue :loop ip.next();
        },
        .lnum => {
            const p = ip.inst().as(.abx);
            vm.store(p.a, vm.interner.consts.items[p.b]);
            continue :loop ip.next();
        },
        .latm => {
            const p = ip.inst().as(.abx);
            vm.store(p.a, .{ .atom = p.b });
            continue :loop ip.next();
        },
        .lstr => {
            const p = ip.inst().as(.abx);
            const s = vm.interner.strings.items[p.b];
            const str = try vm.gpa.create(StrObj);
            str.* = .{
                .rc = 1,
                .buffer = try vm.gpa.dupe(u8, s),
            };
            vm.store(p.a, .{ .str = str });
            continue :loop ip.next();
        },
        .arr => {
            const p = ip.inst().as(.abc);
            const src_e = r[p.b..][0..p.c];
            const elems = try vm.gpa.dupe(Value, src_e);
            @memset(src_e, .nil);
            const arr = try vm.gpa.create(ArrayObj);
            arr.* = ArrayObj{
                .rc = 1,
                .elems = .fromOwnedSlice(elems),
            };
            vm.store(p.a, arr);
            continue :loop ip.next();
        },
        .rec => {
            const p = ip.inst().as(.abc);
            const src_e = r[p.b..][0..(2 * p.c)];

            const rec = try vm.gpa.create(RecordObj);
            rec.* = RecordObj{ .rc = 1, .map = .empty };
            try rec.map.ensureTotalCapacity(vm.gpa, p.c);
            for (0..p.c) |i| {
                const ki = i * 2;
                const vi = (i * 2) + 1;
                const k = src_e[ki];
                std.debug.assert(k == .atom);
                rec.map.putAssumeCapacity(k.atom, src_e[vi]);
                src_e[ki] = .nil;
                src_e[vi] = .nil;
            }
            try vm.store(p.a, .{ .rec = rec });
            continue :loop ip.next();
        },
        inline .neg, .not => |op| {
            try vm.unop(op, r);
            continue :loop ip.next();
        },
        inline .add, .sub, .mul, .div, .mod, .eql, .lt, .gt => |op| {
            try vm.binop(op, r);
            continue :loop ip.next();
        },
        .geti => {
            try vm.getIdx();
            continue :loop ip.next();
        },
        .seti => {
            try vm.setIdx();
            continue :loop ip.next();
        },
        .jmp => {
            const p = ip.inst().as(.sbx);
            continue :loop ip.goto(p.sbx);
        },
        .jmf => {
            const p = ip.inst().as(.sbx);
            if (!r[p.a].truthy()) {
                continue :loop ip.goto(p.sbx);
            }
            continue :loop ip.next();
        },
        .jmt => {
            const p = ip.inst().as(.sbx);
            if (r[p.a].truthy()) {
                continue :loop ip.goto(p.sbx);
            }
            continue :loop ip.next();
        },
        .call => {
            const p = ip.inst().as(.abx);
            const f = fns[p.bx];
            try call_stack.append(vm.gpa, .{
                .saved_frame_base = frame_base,
                .saved_frame_len = r.len,
                .ret_pc = ip.pc + 1,
            });

            frame_base += p.a;
            const top = frame_base + f.max_reg;
            if (vm.regs.items.len < top) {
                vm.regs.appendNTimes(vm.gpa, .nil, top - vm.regs.items.len);
            }
            r = vm.regs.items[frame_base..top];
            ip.pc = f.body.entry;
            continue :loop vm.trace(ip.inst(), ip.pc);
        },
        .calln => {
            const p = ip.inst().as(.abc);
            const f = fns[p.b];

            if (f.arity) |arity| {
                if (arity != p.c) return error.WrongNumbertOfArgs;
            }
            const args = r[p.a..][0..p.c];
            const res = try f.body.native(vm, args);
            for (args) |a| a.release(vm.gpa);
            @memset(args, .nil);
            vm.store(r, p.a, res);
            continue :loop ip.next();
        },
        .ret => {
            const p = ip.inst().as(.abc);
            const res = r[p.a];
            r[p.a] = .taken;
            for (r) |e| {
                e.release(vm.gpa);
            }
            @memset(r, .nil);
            vm.store(r, 0, res);
            const frame = call_stack.pop().?;
            frame_base = frame.saved_frame_base;
            r = vm.regs.items[frame_base..][0..frame.saved_frame_len];
            ip.pc = frame.ret_pc;
            continue :loop vm.trace(ip.inst(), ip.pc);
        },
        .iter_begin => {
            const p = ip.inst().as(.abc);
            const it = vm.stack.items[vm.stack.items.len - 1];
            switch (it) {
                .arr, .rec => {},
                else => return vm.fail("cannot iterate over {f}", .{it.fmt(vm.interner)}),
            }
            try vm.stack.append(vm.gpa, .{ .idx = 0 });
            try vm.stack.appendNTimes(vm.gpa, .nil, n);
            continue :loop vm.trace(next(&pc, insts), pc);
        },
        .iter_next => {
            const p: IterPayload = @bitCast(insts[pc].pld);
            const it = vm.stack.items[vm.stack.items.len - p.n - 2];
            const cur = &vm.stack.items[vm.stack.items.len - p.n - 1];
            const i = cur.idx; // must be index

            const count = switch (it) {
                .arr => |a| a.elems.items.len,
                .rec => |r| r.map.count(),
                else => unreachable,
            };

            if (i >= count) {
                pc = p.exit;
                continue :loop vm.trace(insts[pc], pc);
            }
            cur.idx += 1;

            const captures = vm.stack.items[vm.stack.items.len - p.n ..];
            switch (p.n) {
                1 => {
                    const v = switch (it) {
                        .arr => |arr| arr.elems.items[@bitCast(i)],
                        .rec => |rec| rec.map.values()[@bitCast(i)],
                        else => unreachable,
                    };
                    captures[0].release(vm.gpa);
                    captures[0] = v.retain();
                },
                2 => {
                    const k: Value, const v: Value = switch (it) {
                        .arr => |arr| .{ .{ .number = @floatFromInt(i) }, arr.elems.items[@bitCast(i)] },
                        .rec => |rec| .{ .{ .atom = rec.map.keys()[@bitCast(i)] }, rec.map.values()[@bitCast(i)] },
                        else => unreachable,
                    };
                    captures[0].release(vm.gpa);
                    captures[0] = k.retain();
                    captures[1].release(vm.gpa);
                    captures[1] = v.retain();
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

// owns v, releases previous value in r[reg]
inline fn store(vm: *Vm, r: []Value, reg: u8, v: Value) void {
    r[reg].release(vm.gpa);
    r[reg] = v;
}

inline fn getIdx(vm: *Vm, inst: Inst, r: []Value) !void {
    const p = inst.as(.abc);
    const target = r[p.b];
    const idx = r[p.c];

    switch (target) {
        .str => return error.Nyi, // TODO: support chars/bytes?
        .arr => |a| {
            if (idx != .number) return error.IdxMustBeInt;
            const i = try floatToIdx(idx.number);
            if (i < 0 or i >= a.elems.items.len) return error.IndexOutOfBounds;
            vm.store(p.a, a.elems.items[@intCast(i)].retain());
        },
        .rec => |rec| {
            if (idx != .atom) return error.IdxMustBeAtom;
            const v: Value = rec.map.get(idx.atom) orelse .nil;
            vm.store(p.a, v.retain());
        },
        else => return error.TargetMustBeIndexable,
    }
}

inline fn setIdx(vm: *Vm, inst: Inst, r: []Value) !void {
    const p = inst.as(.abc);
    const target = r[p.a];
    const idx = r[p.b];
    const val = r[p.c];

    switch (target) {
        .arr => |a| {
            if (idx != .number) return error.IdxMustBeInt;
            const i = try floatToIdx(idx.number);
            if (i < 0 or i >= a.elems.items.len) return error.IndexOutOfBounds;
            const x = try a.ensureUnique(vm.gpa);

            x.elems.items[i].release(vm.gpa);
            x.elems.items[i] = val.retain();
            vm.store(p.a, .{ .arr = x });
        },
        .rec => |rec| {
            if (idx != .atom) return error.IdxMustBeAtom;
            const x = try rec.ensureUnique(vm.gpa);

            const gop = try x.map.getOrPut(vm.gpa, idx.atom);
            if (gop.found_existing) {
                gop.value_ptr.*.release(vm.gpa);
            }
            gop.value_ptr.* = val.retain();
            vm.store(p.a, .{ .rec = x });
        },
        else => return error.TargetMustBeIndexable,
    }
}

inline fn floatToIdx(f: f64) !usize {
    if (f < 0) return error.IndexOutOfBounds;
    if (f > @floor(f)) return error.IdxMustBeWhole;
    return @trunc(f);
}

inline fn binop(vm: *Vm, comptime op: Inst.Op) !void {
    var b = vm.stack.pop().?;
    var a = vm.stack.pop().?;
    defer a.release(vm.gpa);
    defer b.release(vm.gpa);

    if (a == .number and b == .number) {
        const r: f64 = switch (op) {
            .add => a.number + b.number,
            .sub => a.number - b.number,
            .mul => a.number * b.number,
            .div => a.number / b.number,
            .mod => @mod(a.number, b.number),
            .eql => @intFromBool(a.number == b.number),
            .lt => @intFromBool(a.number < b.number),
            .gt => @intFromBool(a.number > b.number),
            else => @compileError("binary op called without an binary operation"),
        };
        return vm.stack.append(vm.gpa, .{ .number = r });
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
        .eql => .{ .number = @intFromBool(a.eql(b)) },
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
                .number => |i| .{ .number = -i },
                else => return error.UnssuportedOpForType,
            };
            try vm.stack.append(vm.gpa, r);
        },
        .not => {
            try vm.stack.append(vm.gpa, .{ .number = @intFromBool(!a.truthy()) });
        },
        else => @compileError("unary op called without an unary operation"),
    }
}
