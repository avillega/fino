src: []const u8,
ast: *Ast,

const Interpreter = @This();

// TODO: the resolver should return the max capacity for globals and locals
pub fn init(i: *Interpreter, ast: *Ast, gpa: Allocator, capacity: struct {
    globals: u32,
    locals: u32,
    values: u32,
}) !void {
    assert(ast.resolved);
    i.src = ast.src;
    i.ast = ast;
}

pub fn interpret(i: *Interpreter) !void {
    for (i.ast.node.tag) |tag| switch (tag) {

        // literals
        .nil => {},
        .num => {},
        .atom => {},
        .str => {},
        .arr => {},
        .record => {},
        // variables
        .dec_param => {},
        .dec_capture => {},
        .dec_var => {},
        .set_var => {},
        .get_var => {},
        .take_var => {},
        // unary expr
        .neg => {},
        .not => {},
        // binary expr
        .add => {},
        .sub => {},
        .mul => {},
        .div => {},
        .mod => {},
        .eql => {},
        .lt => {},
        .gt => {},
        // indexing operations
        .get_idx => {},
        .set_idx => {},
        // function related
        .call => {},
        .ret => {},
        // markers
        .scope_begin => {},
        .scope_end => {},
        .fn_begin => {},
        .fn_end => {}, // this should use fun repr
        .if_then => {},
        .if_else => {},
        .if_end_else => {},
        .if_end => {},
        .and_then => {},
        .and_end => {},
        .or_then => {},
        .or_end => {},
        .while_begin => {},
        .while_do => {},
        .while_end => {},
        .for_do => {},
        .for_end => {},

        .discard => {},
    };
}

const Allocator = std.mem.Allocator;
const Ast = @import("Ast.zig");
const assert = std.debug.assert();
const std = @import("std");
