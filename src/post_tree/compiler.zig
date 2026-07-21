const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Program = @import("Program.zig");
const Vm = @import("../Vm.zig");

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
    };
    defer c.locals.deinit(prog.gpa);

    const start = prog.insts.items.len;
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

    fn compileBody(c: *Compiler) CompilerError!void {
        while (c.i < c.ast.len) {
            const node = c.ast[c.i];
            c.i += 1;
            switch (node) {
                .scope_end, .fn_end, .while_end, .while_do, .if_else, .if_end => {
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
                .arr_lit => |elem_cnt| try c.emitPld(.arr_lit, elem_cnt),
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
                    try c.locals.append(c.prog.gpa, id);
                },
                .dec_var => |id| {
                    if (c.frame == null) {
                        try c.emitPld(.dec_glob, id);
                    } else {
                        try c.locals.append(c.prog.gpa, id);
                    }
                },
                .get_var => |id| {
                    if (c.findVarIdx(id)) |idx| {
                        try c.emitPld(.get_locl, @intCast(idx));
                    } else {
                        try c.emitPld(.get_glob, id);
                    }
                },
                .set_var => |id| {
                    if (c.findVarIdx(id)) |idx| {
                        try c.emitPld(.set_locl, @intCast(idx));
                    } else {
                        try c.emitPld(.set_glob, id);
                    }
                },
                .scope_begin => try c.compileScope(),
                .fn_begin => |f| try c.compileFn(f),
                .if_then => try c.compileIf(),
                .while_begin => try c.compileWhile(),
            }
        }
    }

    fn compileFn(c: *Compiler, f: Parser.Node.VariantType(.fn_begin)) CompilerError!void {
        const idx = c.prog.fn_map.get(f.id) orelse return error.FnNotDefined;
        const patch = c.prog.insts.items.len;
        try c.emit(.jmp);
        c.prog.fn_table.items[idx].body = .{ .entry = c.prog.insts.items.len };

        const curr_frame = c.frame;
        c.frame = c.locals.items.len;
        defer c.frame = curr_frame;
        defer c.locals.items.len = c.frame.?;

        try c.compileBody();
        std.debug.assert(c.ast[c.i] == .fn_end);
        c.i += 1;

        try c.emit(.nil);
        try c.emit(.ret);
        c.prog.insts.items[patch].pld = @intCast(c.prog.insts.items.len);
    }

    fn compileScope(c: *Compiler) CompilerError!void {
        const locals_start = c.locals.items.len;
        try c.compileBody();
        std.debug.assert(c.ast[c.i] == .scope_end);
        c.i += 1;
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
        const patch_jze = c.prog.insts.items.len;
        try c.emit(.jmpf); // must be patched
        try c.compileBody();
        switch (c.ast[c.i]) {
            .if_end => {
                c.i += 1; // eat .if_end
                c.prog.insts.items[patch_jze].pld = @intCast(c.prog.insts.items.len); // patch jze
            },
            .if_else => {
                c.i += 1; // eat .if_else
                const patch_jmp = c.prog.insts.items.len;
                try c.emit(.jmp);
                c.prog.insts.items[patch_jze].pld = @intCast(c.prog.insts.items.len); // patch jze

                try c.compileBody();
                c.prog.insts.items[patch_jmp].pld = @intCast(c.prog.insts.items.len); // patch jmp
                std.debug.assert(c.ast[c.i] == .if_end);
                c.i += 1;
            },
            else => unreachable,
        }
    }

    fn compileWhile(c: *Compiler) CompilerError!void {
        const loop_top = c.prog.insts.items.len;
        try c.compileBody(); // compiles the condition
        std.debug.assert(c.ast[c.i] == .while_do);
        c.i += 1;
        const patch_jze = c.prog.insts.items.len;
        try c.emit(.jmpf);
        try c.compileBody(); // compiles the body of the while
        std.debug.assert(c.ast[c.i] == .while_end);
        c.i += 1;
        try c.emitPld(.jmp, @intCast(loop_top));
        c.prog.insts.items[patch_jze].pld = @intCast(c.prog.insts.items.len);
    }

    fn emit(c: *Compiler, comptime op: Vm.Inst.Op) !void {
        try c.emitPld(op, 0);
    }

    fn emitPld(c: *Compiler, comptime op: Vm.Inst.Op, pld: u24) !void {
        try c.prog.insts.append(c.prog.gpa, .{ .op = op, .pld = pld });
    }
};
