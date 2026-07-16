const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Vm = @import("../Vm.zig");

const CompilerError = error{
    DuplicatedFn,
    FnNotDefined,
    WrongNumberOfArgs,
} || Allocator.Error;

const Local = struct {
    id: u24,
};

pub fn collectFns(
    gpa: Allocator,
    ast: Parser.Ast,
    fn_map: *std.AutoHashMapUnmanaged(u24, u24), // from fn_id to location in the fn table
    fn_table: *std.ArrayList(Vm.FnInfo),
) !void {
    for (ast) |node| {
        switch (node) {
            .fn_begin => |f| {
                if (fn_map.contains(f.id)) return error.DuplicatedFn;

                try fn_map.put(gpa, f.id, @intCast(fn_table.items.len));
                try fn_table.append(gpa, .{ .name_id = f.id, .arity = f.arity });
            },
            else => {},
        }
    }
}

const Context = struct {
    i: usize,
    frame: ?usize,
    locals: std.ArrayList(Local),

    pub fn deinit(c: *Context, gpa: Allocator) void {
        c.locals.deinit(gpa);
    }
};

pub fn compile(
    gpa: Allocator,
    ast: Parser.Ast,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
) CompilerError!usize {
    var ctx: Context = .{
        .i = 0,
        .frame = null,
        .locals = .empty,
    };
    defer ctx.deinit(gpa);
    const start = insts.items.len;
    try compileBody(&ctx, gpa, ast, insts, fn_map, fn_table);
    try emit(gpa, insts, .halt);
    return start;
}

fn compileBody(
    ctx: *Context,
    gpa: Allocator,
    ast: Parser.Ast,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
) CompilerError!void {
    while (ctx.i < ast.len) {
        const node = ast[ctx.i];
        ctx.i += 1;
        switch (node) {
            .scope_end, .fn_end, .while_end, .while_do, .if_else, .if_end => {
                ctx.i -= 1; // will be checked by the caller
            },
            .neg_expr => try emit(gpa, insts, .neg),
            .not_expr => try emit(gpa, insts, .not),
            .add_expr => try emit(gpa, insts, .add),
            .sub_expr => try emit(gpa, insts, .sub),
            .mul_expr => try emit(gpa, insts, .mul),
            .div_expr => try emit(gpa, insts, .div),
            .eql_expr => try emit(gpa, insts, .eql),
            .not_eql_expr => {
                try emit(gpa, insts, .eql);
                try emit(gpa, insts, .not);
            },
            .lt_expr => try emit(gpa, insts, .lt),
            .lt_eql_expr => {
                try emit(gpa, insts, .gt);
                try emit(gpa, insts, .not);
            },
            .gt_expr => try emit(gpa, insts, .gt),
            .gt_eql_expr => {
                try emit(gpa, insts, .lt);
                try emit(gpa, insts, .not);
            },
            .nil => try emit(gpa, insts, .nil),
            .const_int => |id| {
                try emitPld(gpa, insts, .const_int, id);
            },
            .call_expr => |call| {
                const f_idx = fn_map.get(call.id) orelse return error.FnNotDefined;
                const f_info = fn_table[f_idx];
                if (f_info.arity != call.arg_c) return error.WrongNumberOfArgs;
                try emitPld(gpa, insts, .call, f_idx);
            },
            .print_stmt => {
                try emit(gpa, insts, .print);
            },
            .return_stmt => {
                try emit(gpa, insts, .ret);
            },
            .expr_stmt => {
                try emit(gpa, insts, .pop);
            },
            .dec_param => |id| {
                try ctx.locals.append(gpa, .{ .id = id });
            },
            .dec_var => |id| {
                if (ctx.frame == null) {
                    try emitPld(gpa, insts, .dec_glob, id);
                } else {
                    try ctx.locals.append(gpa, .{ .id = id });
                }
            },
            .get_var => |id| {
                if (findVarIdx(ctx, id)) |idx| {
                    try emitPld(gpa, insts, .get_locl, @intCast(idx));
                } else {
                    try emitPld(gpa, insts, .get_glob, id);
                }
            },
            .set_var => |id| {
                if (findVarIdx(ctx, id)) |idx| {
                    try emitPld(gpa, insts, .set_locl, @intCast(idx));
                } else {
                    try emitPld(gpa, insts, .set_glob, id);
                }
            },
            .scope_begin => try compileScope(ctx, gpa, ast, insts, fn_map, fn_table),
            .fn_begin => |f| try compileFn(ctx, gpa, f, ast, insts, fn_map, fn_table),
            .if_then => try compileIf(ctx, gpa, ast, insts, fn_map, fn_table),
            .while_begin => try compileWhile(ctx, gpa, ast, insts, fn_map, fn_table),
            // else => |n| std.debug.panic("nyi: {t}", .{n}),
        }
    }
}

fn compileFn(
    ctx: *Context,
    gpa: Allocator,
    f: Parser.Node.VariantType(.fn_begin),
    ast: Parser.Ast,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
) CompilerError!void {
    const idx = fn_map.get(f.id) orelse return error.FnNotDefined;
    const patch = insts.items.len;
    try emit(gpa, insts, .jmp);
    fn_table[idx].entry_point = insts.items.len;
    const curr_frame = ctx.frame;
    ctx.frame = ctx.locals.items.len;
    defer ctx.frame = curr_frame;
    defer ctx.locals.items.len = ctx.frame.?;

    try compileBody(ctx, gpa, ast, insts, fn_map, fn_table);
    std.debug.assert(ast[ctx.i] == .fn_end);
    ctx.i += 1;

    try emit(gpa, insts, .nil);
    try emit(gpa, insts, .ret);
    insts.items[patch].pld = @intCast(insts.items.len);
}

fn compileScope(
    ctx: *Context,
    gpa: Allocator,
    ast: Parser.Ast,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
) CompilerError!void {
    const locals_start = ctx.locals.items.len;
    try compileBody(ctx, gpa, ast, insts, fn_map, fn_table);
    const count = ctx.locals.items.len - locals_start;
    if (count > 0) try emitPld(gpa, insts, .pop_n, @intCast(count));
}

fn findVarIdx(ctx: *Context, id: u24) ?usize {
    const frame_start: usize = ctx.frame orelse 0;
    const frame = ctx.locals.items[frame_start..];
    var idx = frame.len;
    var f_it = std.mem.reverseIterator(frame);
    while (f_it.next()) |local| {
        idx -= 1;
        if (id == local.id) {
            return idx;
        }
    }
    return null;
}

fn compileIf(
    ctx: *Context,
    gpa: Allocator,
    ast: Parser.Ast,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
) CompilerError!void {
    // cond is already compiled at this point
    const patch_jze = insts.items.len;
    try emit(gpa, insts, .jze); // must be patched
    try compileBody(ctx, gpa, ast, insts, fn_map, fn_table);
    switch (ast[ctx.i]) {
        .if_end => {
            ctx.i += 1; // eat .if_end
            insts.items[patch_jze].pld = @intCast(insts.items.len); // patch jze
        },
        .if_else => {
            ctx.i += 1; // eat .if_else
            const patch_jmp = insts.items.len;
            try emit(gpa, insts, .jmp);
            insts.items[patch_jze].pld = @intCast(insts.items.len); // patch jze

            try compileBody(ctx, gpa, ast, insts, fn_map, fn_table);
            insts.items[patch_jmp].pld = @intCast(insts.items.len); // patch jmp
            std.debug.assert(ast[ctx.i] == .if_end);
            ctx.i += 1;
        },
        else => unreachable,
    }
}

fn compileWhile(
    ctx: *Context,
    gpa: Allocator,
    ast: Parser.Ast,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
) CompilerError!void {
    const loop_top = insts.items.len;
    try compileBody(ctx, gpa, ast, insts, fn_map, fn_table); // compiles the condition
    std.debug.assert(ast[ctx.i] == .while_do);
    ctx.i += 1;
    const patch_jze = insts.items.len;
    try emit(gpa, insts, .jze);
    try compileBody(ctx, gpa, ast, insts, fn_map, fn_table); // compiles the body of the while
    std.debug.assert(ast[ctx.i] == .while_end);
    ctx.i += 1;
    try emitPld(gpa, insts, .jmp, @intCast(loop_top));
    insts.items[patch_jze].pld = @intCast(insts.items.len);
}

fn emit(gpa: Allocator, insts: *std.ArrayList(Vm.Inst), comptime op: Vm.Inst.Op) !void {
    try emitPld(gpa, insts, op, 0);
}

fn emitPld(gpa: Allocator, insts: *std.ArrayList(Vm.Inst), comptime op: Vm.Inst.Op, pld: u24) !void {
    try insts.append(gpa, .{ .op = op, .pld = pld });
}
