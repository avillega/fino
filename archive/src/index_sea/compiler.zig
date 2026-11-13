const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Vm = @import("../Vm.zig");

const Local = struct {
    depth: u16,
    id: u24,
};

pub fn collectFns(
    gpa: Allocator,
    ast: Parser.Ast,
    fn_map: *std.AutoHashMapUnmanaged(u24, u24), // from fn_id to location in the fn table
    fn_table: *std.ArrayList(Vm.FnInfo),
) !void {
    for (ast.nodes) |node| {
        switch (node) {
            .fndef => |f| {
                if (fn_map.contains(f.id)) return error.DuplicatedFn;
                try fn_map.put(gpa, f.id, @intCast(fn_table.items.len));
                try fn_table.append(gpa, .{ .name_id = f.id, .arity = @intCast(f.arity) });
            },
            else => {},
        }
    }
}

pub fn compile(
    gpa: Allocator,
    ast: Parser.Ast,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
) !usize {
    var locals: std.ArrayList(Local) = .empty;
    defer locals.deinit(gpa);
    const start = insts.items.len;
    try do_compile(gpa, ast, Parser.NodeIdx.from(@intCast(ast.nodes.len - 1)), insts, fn_map, fn_table, &locals, 0);
    try insts.append(gpa, .{ .op = .halt });
    return start;
}

fn do_compile(
    gpa: Allocator,
    ast: Parser.Ast,
    node_idx: Parser.NodeIdx,
    insts: *std.ArrayList(Vm.Inst),
    fn_map: *std.AutoHashMapUnmanaged(u24, u24),
    fn_table: []Vm.FnInfo,
    locals: *std.ArrayList(Local),
    depth: u16,
) !void {
    const node = ast.nodes[node_idx.to()];
    switch (node) {
        .root => |block| {
            for (ast.extra[block.start.to()..][0..block.len]) |n| {
                try do_compile(gpa, ast, n, insts, fn_map, fn_table, locals, depth);
            }
        },
        .scope => |block| {
            for (ast.extra[block.start.to()..][0..block.len]) |n| {
                try do_compile(gpa, ast, n, insts, fn_map, fn_table, locals, depth + 1);
            }
            var count: u24 = 0;
            loop: for (0..locals.items.len) |i| {
                const idx = locals.items.len - 1 - i;
                if (depth + 1 != locals.items[idx].depth) {
                    break :loop;
                }
                count += 1;
            }
            locals.items.len = locals.items.len - count;
            if (count > 0) {
                try insts.append(gpa, .{ .op = .pop_n, .pld = @intCast(count) });
            }
        },
        .nil => {
            try insts.append(gpa, .{ .op = .nil });
        },
        .const_int => |id| {
            try insts.append(gpa, .{ .op = .const_int, .pld = id });
        },
        .dec_param => |id| {
            try locals.append(gpa, .{ .id = id, .depth = depth });
        },
        .dec_var => |v| {
            try do_compile(gpa, ast, v.expr, insts, fn_map, fn_table, locals, depth);
            if (depth == 0) {
                try insts.append(gpa, .{ .op = .dec_glob, .pld = v.id });
            } else {
                try locals.append(gpa, .{ .id = v.id, .depth = depth });
            }
        },
        .set_var => |v| {
            try do_compile(gpa, ast, v.expr, insts, fn_map, fn_table, locals, depth);
            if (depth == 0) {
                try insts.append(gpa, .{ .op = .set_glob, .pld = v.id });
                return;
            }

            var i = locals.items.len - 1;
            loop: while (i >= 0) : (i -= 1) {
                if (v.id == locals.items[i].id) {
                    try insts.append(gpa, .{ .op = .set_locl, .pld = @intCast(i) });
                    break :loop;
                }
            } else {
                try insts.append(gpa, .{ .op = .set_glob, .pld = v.id });
            }
        },
        .get_var => |id| {
            if (depth == 0) {
                try insts.append(gpa, .{ .op = .get_glob, .pld = id });
                return;
            }

            loop: for (0..locals.items.len) |i| {
                const idx = locals.items.len - 1 - i;
                if (id == locals.items[idx].id) {
                    try insts.append(gpa, .{ .op = .get_locl, .pld = @intCast(idx) });
                    break :loop;
                }
            } else {
                try insts.append(gpa, .{ .op = .get_glob, .pld = id });
            }
        },
        .neg_expr, .not_expr, .print_stmt, .return_stmt, .expr_stmt => |unary| {
            try do_compile(gpa, ast, unary.expr, insts, fn_map, fn_table, locals, depth);
            const op: Vm.Inst.Op = switch (node) {
                .neg_expr => .neg,
                .not_expr => .not,
                .print_stmt => .print,
                .return_stmt => .ret,
                .expr_stmt => .pop,
                else => unreachable,
            };
            try insts.append(gpa, .{ .op = op });
        },
        .add_expr,
        .sub_expr,
        .mul_expr,
        .div_expr,
        .eql_expr,
        .nql_expr,
        .lt_expr,
        .lql_expr,
        .gt_expr,
        .gql_expr,
        => |binary| {
            try do_compile(gpa, ast, binary.lhs, insts, fn_map, fn_table, locals, depth);
            try do_compile(gpa, ast, binary.rhs, insts, fn_map, fn_table, locals, depth);
            const ops: [2]?Vm.Inst.Op = switch (node) {
                .add_expr => [_]?Vm.Inst.Op{ .add, null },
                .sub_expr => [_]?Vm.Inst.Op{ .sub, null },
                .mul_expr => [_]?Vm.Inst.Op{ .mul, null },
                .div_expr => [_]?Vm.Inst.Op{ .div, null },
                .eql_expr => [_]?Vm.Inst.Op{ .eql, null },
                .nql_expr => [_]?Vm.Inst.Op{ .eql, .not },
                .lt_expr => [_]?Vm.Inst.Op{ .lt, null },
                .lql_expr => [_]?Vm.Inst.Op{ .gt, .not },
                .gt_expr => [_]?Vm.Inst.Op{ .gt, null },
                .gql_expr => [_]?Vm.Inst.Op{ .lt, .not },
                else => unreachable,
            };
            for (ops) |op| {
                if (op) |o| try insts.append(gpa, .{ .op = o });
            }
        },
        .call_expr => |call| {
            const f_idx = fn_map.get(call.id) orelse return error.FnNotDefined;
            const f_info = fn_table[f_idx];
            if (f_info.arity != call.args.len) return error.WrongNumberOfArgs;
            for (ast.extra[call.args.start.to()..][0..call.args.len]) |arg| {
                try do_compile(gpa, ast, arg, insts, fn_map, fn_table, locals, depth);
            }
            try insts.append(gpa, .{ .op = .call, .pld = f_idx });
        },
        .fndef => |fnd| {
            const f_idx = fn_map.get(fnd.id) orelse unreachable;
            const patch = insts.items.len;
            try insts.append(gpa, .{ .op = .jmp }); // must be patched

            fn_table[f_idx].entry_point = insts.items.len;

            var f_locals: std.ArrayList(Local) = .empty;
            defer f_locals.deinit(gpa);

            for (ast.extra[fnd.body.start.to()..][0..fnd.body.len]) |n| {
                try do_compile(gpa, ast, n, insts, fn_map, fn_table, &f_locals, depth + 1);
            }

            try insts.append(gpa, .{ .op = .nil });
            try insts.append(gpa, .{ .op = .ret });
            std.debug.assert(insts.items[patch].op == .jmp);
            insts.items[patch].pld = @intCast(insts.items.len);
        },
        .if_stmt => |if_s| {
            try do_compile(gpa, ast, if_s.cond, insts, fn_map, fn_table, locals, depth + 1);
            const cond_patch = insts.items.len;
            try insts.append(gpa, .{ .op = .jmpf }); // must be patched

            try do_compile(gpa, ast, if_s.then_branch, insts, fn_map, fn_table, locals, depth + 1);

            const then_patch = insts.items.len;
            try insts.append(gpa, .{ .op = .jmp }); // must be patched

            std.debug.assert(insts.items[cond_patch].op == .jmpf);
            insts.items[cond_patch].pld = @intCast(insts.items.len);

            if (if_s.else_branch != .none) {
                try do_compile(gpa, ast, if_s.else_branch, insts, fn_map, fn_table, locals, depth + 1);
            }

            std.debug.assert(insts.items[then_patch].op == .jmp);
            insts.items[then_patch].pld = @intCast(insts.items.len);
        },
        .while_stmt => |while_s| {
            const cond_start = insts.items.len;

            try do_compile(gpa, ast, while_s.cond, insts, fn_map, fn_table, locals, depth + 1);
            const cond_patch = insts.items.len;
            try insts.append(gpa, .{ .op = .jmpf }); // must be patched

            try do_compile(gpa, ast, while_s.body, insts, fn_map, fn_table, locals, depth + 1);

            try insts.append(gpa, .{ .op = .jmp, .pld = @intCast(cond_start) });

            std.debug.assert(insts.items[cond_patch].op == .jmpf);
            insts.items[cond_patch].pld = @intCast(insts.items.len);
        },
    }
}
