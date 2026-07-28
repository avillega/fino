const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Program = @import("Program.zig");
const Vm = @import("../Vm.zig");

const NodeTag = std.meta.Tag(Parser.Node);

const CompilerError = error{
    DuplicatedFn,
    FnNotDefined,
    WrongNumberOfArgs,
} || Allocator.Error;

pub fn compile(prog: *Program, ast: Parser.Ast) CompilerError!usize {
    try collectFns(prog, ast);
    var c: Compiler = .{
        .prog = prog,
        .ast = ast,
        .i = 0,
        .frame = null,
        .locals = .empty,
        .depth = 0,
    };
    defer c.locals.deinit(prog.gpa);

    const start = c.nextAddr();
    try c.compileBody();
    try c.emit(.halt);
    return start;
}

fn collectFns(prog: *Program, ast: Parser.Ast) CompilerError!void {
    for (ast) |node| {
        switch (node) {
            .fn_begin => |f| {
                if (prog.fn_map.contains(f.id)) return error.DuplicatedFn;

                try prog.fn_map.put(prog.gpa, f.id, @intCast(prog.fn_table.items.len));
                try prog.fn_table.append(prog.gpa, .{ .name_id = f.id, .arity = f.arity });
            },
            else => {},
        }
    }
}

const Compiler = struct {
    prog: *Program,
    ast: Parser.Ast,
    i: usize,
    frame: ?usize, // start of the current fn frame in locals; null at top level
    locals: std.ArrayList(u24),
    depth: u32,

    fn compileBody(c: *Compiler) CompilerError!void {
        var pending_take: ?u24 = null;
        while (c.i < c.ast.len) {
            const node = c.ast[c.i];
            c.i += 1;
            switch (node) {
                .dec_capture => unreachable, // handled in compileFor, never in compileBody
                .scope_end, .fn_end, .while_end, .while_do, .if_else, .if_end, .for_end => {
                    c.i -= 1; // will be checked by the caller
                    return;
                },
                .neg_expr => try c.emit(.neg),
                .not_expr => try c.emit(.not),
                .add_expr => try c.emit(.add),
                .sub_expr => try c.emit(.sub),
                .mul_expr => try c.emit(.mul),
                .div_expr => try c.emit(.div),
                .eql_expr => try c.emit(.eql),
                .not_eql_expr => {
                    try c.emit(.eql);
                    try c.emit(.not);
                },
                .lt_expr => try c.emit(.lt),
                .lt_eql_expr => {
                    try c.emit(.gt);
                    try c.emit(.not);
                },
                .gt_expr => try c.emit(.gt),
                .gt_eql_expr => {
                    try c.emit(.lt);
                    try c.emit(.not);
                },
                .nil => try c.emit(.nil),
                .const_int => |id| try c.emitPld(.const_int, id),
                .str_lit => |id| try c.emitPld(.str_lit, id),
                .atom => |id| try c.emitPld(.atom, id),
                .arr_lit => |elem_cnt| try c.emitPld(.arr_lit, elem_cnt),
                .record_lit => |pair_cnt| try c.emitPld(.record_lit, pair_cnt),
                .get_index => try c.emit(.get_index),
                .set_index => |id| {
                    if (c.findVarIdx(id)) |slot| {
                        try c.emitPld(.take_locl, @intCast(slot));
                        try c.emit(.set_index);
                        try c.emitPld(.set_locl, @intCast(slot));
                    } else {
                        try c.emitPld(.take_glob, id);
                        try c.emit(.set_index);
                        try c.emitPld(.put_glob, id);
                    }
                },
                .call_expr => |call| {
                    const f_idx = c.prog.fn_map.get(call.id) orelse return error.FnNotDefined;
                    const f_info = c.prog.fn_table.items[f_idx];
                    switch (f_info.body) {
                        .native => try c.emitPld(
                            .call_native,
                            @bitCast(Vm.CallPayload{
                                .fn_idx = @intCast(f_idx),
                                .arity = call.arg_c,
                            }),
                        ),
                        .entry => {
                            if (f_info.arity != call.arg_c) return error.WrongNumberOfArgs;
                            try c.emitPld(.call, f_idx);
                        },
                    }
                },
                .return_stmt => {
                    try c.emit(.ret);
                },
                .expr_stmt => {
                    try c.emit(.pop);
                },
                .dec_param => |id| {
                    try c.emitLocal(id);
                },
                .dec_var => |id| {
                    if (c.depth == 0) {
                        try c.emitPld(.dec_glob, id);
                    } else {
                        try c.emitLocal(id);
                    }
                },
                .get_var => |id| {
                    if (c.findVarIdx(id)) |idx| {
                        try c.emitPld(.get_locl, @intCast(idx));
                    } else {
                        try c.emitPld(.get_glob, id);
                    }
                },
                .take_var => |id| {
                    if (c.findVarIdx(id)) |idx| {
                        try c.emitPld(.take_locl, @intCast(idx));
                    } else {
                        pending_take = id;
                        try c.emitPld(.take_glob, id);
                    }
                },
                .set_var => |id| {
                    if (c.findVarIdx(id)) |idx| {
                        try c.emitPld(.set_locl, @intCast(idx));
                    } else {
                        if (pending_take) |taken_id| {
                            std.debug.assert(taken_id == id);
                            try c.emitPld(.put_glob, id);
                        } else {
                            try c.emitPld(.set_glob, id);
                        }
                    }
                },
                .scope_begin => try c.compileScope(),
                .fn_begin => |f| try c.compileFn(f),
                .if_then => try c.compileIf(),
                .while_begin => try c.compileWhile(),
                .for_do => try c.compileFor(),
            }
        }
    }

    fn compileFor(c: *Compiler) CompilerError!void {
        const hidden_slot = comptime std.math.maxInt(u24);

        const locals_start = c.locals.items.len;
        defer c.locals.items.len = locals_start;

        try c.locals.appendNTimes(c.prog.gpa, hidden_slot, 2);

        var n: u4 = 0;
        while (c.ast[c.i] == .dec_capture) : (c.i += 1) {
            try c.emitLocal(c.ast[c.i].dec_capture);
            n += 1;
        }

        try c.emitPld(.iter_begin, n);
        const loop_top = c.nextAddr();

        const to_exit = c.nextAddr(); //iter_next addr to patch it later
        try c.emitPld(.iter_next, @bitCast(Vm.IterPayload{ .n = n, .exit = 0 })); // must be patched

        try c.compileBody();
        c.expectNode(.for_end);

        try c.emitPld(.jmp, @intCast(loop_top));
        c.prog.insts.items[to_exit].pld = @bitCast(Vm.IterPayload{ .n = n, .exit = @intCast(c.nextAddr()) });

        try c.emitPld(.pop_n, @intCast(n + 2));
    }

    fn compileFn(c: *Compiler, f: Parser.Node.VariantType(.fn_begin)) CompilerError!void {
        const idx = c.prog.fn_map.get(f.id) orelse return error.FnNotDefined;
        const jmp = try c.emitJump(.jmp); // jump over the body
        c.prog.fn_table.items[idx].body = .{ .entry = c.nextAddr() };

        const curr_frame = c.frame;
        c.frame = c.locals.items.len;
        defer c.frame = curr_frame;
        defer c.locals.items.len = c.frame.?;

        try c.compileBody();
        c.expectNode(.fn_end);

        try c.emit(.nil);
        try c.emit(.ret);
        c.patch(jmp);
    }

    fn compileScope(c: *Compiler) CompilerError!void {
        const locals_start = c.locals.items.len;
        c.depth += 1;
        defer c.depth -= 1;
        try c.compileBody();
        c.expectNode(.scope_end);
        const count = c.locals.items.len - locals_start;
        if (count > 0) try c.emitPld(.pop_n, @intCast(count));
    }

    fn findVarIdx(c: *Compiler, id: u24) ?usize {
        const frame_start: usize = c.frame orelse 0;
        const frame = c.locals.items[frame_start..];
        var idx = frame.len;
        var f_it = std.mem.reverseIterator(frame);
        while (f_it.next()) |local| {
            idx -= 1;
            if (id == local) {
                return idx;
            }
        }
        return null;
    }

    fn compileIf(c: *Compiler) CompilerError!void {
        // cond is already compiled at this point
        const jze = try c.emitJump(.jmpf);
        try c.compileBody();
        switch (c.ast[c.i]) {
            .if_end => {
                c.expectNode(.if_end);
                c.patch(jze);
            },
            .if_else => {
                c.expectNode(.if_else);
                const jmp = try c.emitJump(.jmp); // jump over the else
                c.patch(jze);

                try c.compileBody();
                c.patch(jmp);
                c.expectNode(.if_end);
            },
            else => unreachable,
        }
    }

    fn compileWhile(c: *Compiler) CompilerError!void {
        const loop_top = c.nextAddr();
        try c.compileBody(); // compiles the condition
        c.expectNode(.while_do);
        const jze = try c.emitJump(.jmpf);
        try c.compileBody(); // compiles the body of the while
        c.expectNode(.while_end);
        try c.emitPld(.jmp, @intCast(loop_top));
        c.patch(jze);
    }

    inline fn nextAddr(c: *Compiler) usize {
        return c.prog.insts.items.len;
    }

    fn emitJump(c: *Compiler, comptime op: Vm.Inst.Op) CompilerError!usize {
        const at = c.nextAddr();
        try c.emit(op);
        return at;
    }

    fn patch(c: *Compiler, pos: usize) void {
        c.prog.insts.items[pos].pld = @intCast(c.nextAddr());
    }

    fn expectNode(c: *Compiler, comptime tag: NodeTag) void {
        std.debug.assert(c.ast[c.i] == tag);
        c.i += 1;
    }

    inline fn emit(c: *Compiler, comptime op: Vm.Inst.Op) !void {
        try c.emitPld(op, 0);
    }

    inline fn emitPld(c: *Compiler, comptime op: Vm.Inst.Op, pld: u24) !void {
        try c.prog.insts.append(c.prog.gpa, .{ .op = op, .pld = pld });
    }

    inline fn emitLocal(c: *Compiler, id: u24) !void {
        try c.locals.append(c.prog.gpa, id);
    }
};
