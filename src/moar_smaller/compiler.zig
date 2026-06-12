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
    for (ast.tags, ast.nodes) |tag, node| {
        switch (tag) {
            .fn_begin => {
                const f = node.fn_begin;
                if (fn_map.contains(f.id)) return error.DuplicatedFn;

                try fn_map.put(gpa, f.id, @intCast(fn_table.items.len));
                try fn_table.append(gpa, .{ .name_id = f.id, .arity = f.arity });
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

    var frames: std.ArrayList(usize) = .empty;
    try frames.append(gpa, 0);
    defer frames.deinit(gpa);

    const start = insts.items.len;

    var depth: u16 = 0;
    var patch_sites: std.ArrayList(u24) = .empty;
    var loop_tops: std.ArrayList(u24) = .empty;
    defer patch_sites.deinit(gpa);
    defer loop_tops.deinit(gpa);

    for (ast.tags, 0..) |tag, i| {
        switch (tag) {
            .neg_expr => try insts.append(gpa, .{ .op = .neg }),
            .not_expr => try insts.append(gpa, .{ .op = .not }),
            .add_expr => try insts.append(gpa, .{ .op = .add }),
            .sub_expr => try insts.append(gpa, .{ .op = .sub }),
            .mul_expr => try insts.append(gpa, .{ .op = .mul }),
            .div_expr => try insts.append(gpa, .{ .op = .div }),
            .eql_expr => try insts.append(gpa, .{ .op = .eql }),
            .nql_expr => {
                try insts.append(gpa, .{ .op = .eql });
                try insts.append(gpa, .{ .op = .not });
            },
            .lt_expr => try insts.append(gpa, .{ .op = .lt }),
            .lql_expr => {
                try insts.append(gpa, .{ .op = .gt });
                try insts.append(gpa, .{ .op = .not });
            },
            .gt_expr => try insts.append(gpa, .{ .op = .gt }),
            .gql_expr => {
                try insts.append(gpa, .{ .op = .lt });
                try insts.append(gpa, .{ .op = .not });
            },
            .nil => {
                try insts.append(gpa, .{ .op = .nil });
            },
            .const_int => {
                try insts.append(gpa, .{ .op = .const_int, .pld = ast.nodes[i].const_int });
            },
            .call_expr => {
                const call = ast.nodes[i].call_expr;
                const f_idx = fn_map.get(call.id) orelse return error.FnNotDefined;
                const f_info = fn_table[f_idx];
                if (f_info.arity != call.arg_c) return error.WrongNumberOfArgs;
                try insts.append(gpa, .{ .op = .call, .pld = f_idx });
            },
            .print_stmt => {
                try insts.append(gpa, .{ .op = .print });
            },
            .return_stmt => {
                try insts.append(gpa, .{ .op = .ret });
            },
            .expr_stmt => {
                try insts.append(gpa, .{ .op = .pop });
            },
            .scope_begin => {
                depth += 1;
            },
            .dec_param => {
                try locals.append(gpa, .{ .id = ast.nodes[i].dec_param, .depth = depth });
            },
            .dec_var => {
                const id = ast.nodes[i].dec_var;
                if (depth == 0) {
                    try insts.append(gpa, .{ .op = .dec_glob, .pld = id });
                } else {
                    try locals.append(gpa, .{ .id = id, .depth = depth });
                }
            },
            .get_var => {
                const id = ast.nodes[i].get_var;
                if (depth == 0) {
                    try insts.append(gpa, .{ .op = .get_glob, .pld = id });
                    continue;
                }

                const fb = frames.items[frames.items.len - 1];

                var idx = locals.items.len;
                loop: while (idx > fb) {
                    idx -= 1;
                    if (id == locals.items[idx].id) {
                        try insts.append(gpa, .{ .op = .get_locl, .pld = @intCast(idx - fb) });
                        break :loop;
                    }
                } else {
                    try insts.append(gpa, .{ .op = .get_glob, .pld = id });
                }
            },
            .set_var => {
                const id = ast.nodes[i].set_var;
                if (depth == 0) {
                    try insts.append(gpa, .{ .op = .set_glob, .pld = id });
                    continue;
                }

                const fb = frames.items[frames.items.len - 1];

                var idx = locals.items.len;
                loop: while (idx > fb) {
                    idx -= 1;
                    if (id == locals.items[idx].id) {
                        try insts.append(gpa, .{ .op = .set_locl, .pld = @intCast(idx - fb) });
                        break :loop;
                    }
                } else {
                    try insts.append(gpa, .{ .op = .set_glob, .pld = id });
                }
            },
            .scope_end => {
                var count: u24 = 0;
                loop: for (0..locals.items.len) |ii| {
                    const idx = locals.items.len - 1 - ii;
                    if (depth != locals.items[idx].depth) {
                        break :loop;
                    }
                    count += 1;
                }
                locals.items.len = locals.items.len - count;
                if (count > 0) {
                    try insts.append(gpa, .{ .op = .pop_n, .pld = @intCast(count) });
                }
                depth -= 1;
            },
            .fn_begin => {
                const f = ast.nodes[i].fn_begin;
                const idx = fn_map.get(f.id) orelse return error.FnDoesNotExists;

                depth += 1;
                try frames.append(gpa, locals.items.len);

                try patch_sites.append(gpa, @intCast(insts.items.len));
                try insts.append(gpa, .{ .op = .jmp, .pld = 0 });
                fn_table[idx].entry_point = insts.items.len;
            },
            .fn_end => {
                const frame_start = frames.pop().?;
                depth -= 1;
                locals.items.len = frame_start;

                try insts.append(gpa, .{ .op = .nil });
                try insts.append(gpa, .{ .op = .ret });
                const patch_site = patch_sites.pop().?;
                insts.items[patch_site].pld = @intCast(insts.items.len);
            },
            .if_then => {
                try patch_sites.append(gpa, @intCast(insts.items.len));
                try insts.append(gpa, .{ .op = .jze }); // must be patched
            },
            .if_else => {
                const patch_site = patch_sites.pop().?;

                try patch_sites.append(gpa, @intCast(insts.items.len)); // append a jmp after the then branch is executed to skip the else branch
                try insts.append(gpa, .{ .op = .jmp }); // must be patched

                insts.items[patch_site].pld = @intCast(insts.items.len); // patch the jze from the if_then
            },
            .if_end => {
                const patch_site = patch_sites.pop().?;
                insts.items[patch_site].pld = @intCast(insts.items.len); // patch either the jze from the if_then or the jmp from if_else at the end of the then branch
            },
            .while_begin => {
                try loop_tops.append(gpa, @intCast(insts.items.len));
            },
            .while_do => {
                try patch_sites.append(gpa, @intCast(insts.items.len));
                try insts.append(gpa, .{ .op = .jze }); // must be patched
            },
            .while_end => {
                try insts.append(gpa, .{ .op = .jmp, .pld = loop_tops.pop().? }); // must be patched
                const patch_site = patch_sites.pop().?;
                insts.items[patch_site].pld = @intCast(insts.items.len); // patch either the jze from the if_then or the jmp from if_else at the end of the then branch
            },
            // else => |n| std.debug.panic("nyi: {t}", .{n}),
        }
    }
    try insts.append(gpa, .{ .op = .halt });
    return start;
}
