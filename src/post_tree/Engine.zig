const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const compiler = @import("compiler.zig");
const Parser = @import("Parser.zig");
const Lexer = @import("../Lexer.zig");
const Vm = @import("../Vm.zig");
const Interner = @import("../Interner.zig");

const Engine = @This();

gpa: Allocator,
w: *Io.Writer,
vm: Vm,
interner: Interner,
insts: std.ArrayList(Vm.Inst),
fn_map: std.AutoHashMapUnmanaged(u24, u24),
fn_table: std.ArrayList(Vm.FnInfo),

pub fn init(w: *Io.Writer, gpa: std.mem.Allocator) Engine {
    return .{
        .gpa = gpa,
        .w = w,
        .vm = .init(w),
        .interner = .init(gpa),
        .insts = .empty,
        .fn_map = .empty,
        .fn_table = .empty,
    };
}

pub fn deinit(self: *Engine) void {
    self.fn_map.deinit(self.gpa);
    self.fn_table.deinit(self.gpa);
    self.insts.deinit(self.gpa);
    self.interner.deinit();
    self.vm.deinit(self.gpa);
}

pub fn run(self: *Engine, src: [:0]const u8) !void {
    var parser: Parser = .init(src, &self.interner);
    const ast = parser.parse(self.gpa) catch |err| {
        const serr = parser.err orelse "";
        try self.w.print("{t} {s}\n", .{ err, serr });
        return;
    };
    defer self.gpa.free(ast);

    try compiler.collectFns(self.gpa, ast, &self.fn_map, &self.fn_table);
    const start = try compiler.compile(self.gpa, ast, &self.insts, &self.fn_map, self.fn_table.items);

    try self.vm.interpret(
        self.gpa,
        start,
        self.insts.items,
        &self.interner,
        self.fn_table.items,
    );
    try self.w.flush();
}

pub fn printTokens(self: *Engine, src: [:0]const u8) !void {
    var lex = Lexer.init(src);
    try Lexer.printTokens(self.w, &lex);
    try self.w.flush();
}

pub fn benchParser(self: *Engine, src: [:0]const u8) !void {
    var parser: Parser = .init(src, &self.interner);
    const ast = try parser.parse(self.gpa);
    defer self.gpa.free(ast);

    try compiler.collectFns(self.gpa, ast, &self.fn_map, &self.fn_table);
    _ = try compiler.compile(self.gpa, ast, &self.insts, &self.fn_map, self.fn_table.items);
}

pub fn printAstSize(self: *Engine, src: [:0]const u8) !void {
    var parser: Parser = .init(src, &self.interner);
    const ast = try parser.parse(self.gpa);
    defer self.gpa.free(ast);

    const bytes = ast.len * @sizeOf(Parser.Node);
    try self.w.print("ast: {d} nodes, {d}B ({d}B/node)\n", .{ ast.len, bytes, @sizeOf(Parser.Node) });
    try self.w.flush();
}

pub fn printAstFlat(self: *Engine, src: [:0]const u8) !void {
    defer self.w.flush() catch unreachable;
    var parser: Parser = .init(src, &self.interner);
    const ast = parser.parse(self.gpa) catch |err| {
        const serr = parser.err orelse "";
        try self.w.print("{t} {s}\n", .{ err, serr });
        try self.w.print("printing partial parsed list\n", .{});
        try self.printFlat(parser.nodes.items);
        return;
    };
    defer self.gpa.free(ast);
    try self.printFlat(ast);
}

pub fn printAstTree(self: *Engine, src: [:0]const u8) !void {
    defer self.w.flush() catch unreachable;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    const alloc = arena.allocator();
    defer arena.deinit();
    var parser: Parser = .init(src, &self.interner);
    const ast = parser.parse(alloc) catch |err| {
        const serr = parser.err orelse "";
        try self.w.print("{t} {s}\n", .{ err, serr });
        try self.w.print("printing partial parsed list\n", .{});
        try self.printFlat(parser.nodes.items);
        return;
    };

    const Item = struct { node: Parser.Node, depth: usize };
    const SubTree = std.ArrayList(Item);
    var stack: std.ArrayList(SubTree) = .empty;

    for (ast) |node| {
        if (node == .scope_begin or node == .fn_begin or node == .while_begin) continue;
        const a = displayArity(node);

        const first = stack.items.len - a;

        var sub_tree: SubTree = .empty;
        try sub_tree.append(alloc, .{ .node = node, .depth = 0 });
        for (stack.items[first..]) |child| {
            for (child.items) |item| {
                try sub_tree.append(alloc, .{ .node = item.node, .depth = item.depth + 1 });
            }
        }

        stack.items.len = first;
        try stack.append(alloc, sub_tree);
    }

    for (stack.items) |sub_tree| {
        for (sub_tree.items) |item| {
            for (0..item.depth) |_| {
                _ = try self.w.write("│ ");
            }

            try self.write_label(item.node);
            _ = try self.w.write("\n");
        }
    }
}

fn printFlat(self: *Engine, ast: Parser.Ast) !void {
    for (ast) |node| {
        try self.w.print("{any}\n", .{node});
    }
}

pub fn printInsts(self: *Engine, src: [:0]const u8) !void {
    var parser: Parser = .init(src, &self.interner);
    const ast = parser.parse(self.gpa) catch |err| {
        const serr = parser.err orelse "";
        try self.w.print("{t} {s}\n", .{ err, serr });
        return;
    };
    defer self.gpa.free(ast);

    try compiler.collectFns(self.gpa, ast, &self.fn_map, &self.fn_table);
    const start = try compiler.compile(self.gpa, ast, &self.insts, &self.fn_map, self.fn_table.items);

    const width = if (self.insts.items.len == 0) 1 else std.math.log10(self.insts.items.len) + 1;

    for (self.insts.items[start..], start..) |it, idx| {
        try self.w.print("{[line]d: >[width]}│ {[instruction]f}\n", .{
            .width = width,
            .line = idx,
            .instruction = it,
        });
    }
    try self.w.flush();
}

fn write_label(self: *Engine, n: Parser.Node) !void {
    switch (n) {
        .const_int => |i| try self.w.print("{t} {d}", .{ n, try self.interner.get_i(i) }),
        .set_var, .dec_var, .dec_param, .get_var => |i| try self.w.print("{t} {s}", .{ n, try self.interner.get_s(i) }),
        .fn_end => |f| try self.w.print("fn {s}", .{try self.interner.get_s(f.id)}),
        .scope_end => try self.w.print("block", .{}),
        .call_expr => |c| try self.w.print("call {s}/{d}", .{ try self.interner.get_s(c.id), c.arg_c }),
        .if_then => try self.w.writeAll("then"),
        .if_else => try self.w.writeAll("else"),
        .if_end => try self.w.writeAll("if"),
        .while_do => try self.w.writeAll("cond"),
        .while_end => try self.w.writeAll("while"),
        else => |node| try self.w.print("{t}", .{node}),
    }
}

inline fn displayArity(n: Parser.Node) u32 {
    return switch (n) {
        .const_int,
        .get_var,
        .dec_param,
        .nil,
        .if_then,
        .if_else,
        => 0,
        .set_var,
        .dec_var,
        .neg_expr,
        .not_expr,
        .print_stmt,
        .return_stmt,
        .expr_stmt,
        .while_do,
        => 1,
        .add_expr,
        .sub_expr,
        .div_expr,
        .mul_expr,
        .eql_expr,
        .not_eql_expr,
        .lt_eql_expr,
        .gt_eql_expr,
        .lt_expr,
        .gt_expr,
        .while_end,
        => 2,
        .call_expr => |c| c.arg_c,
        .if_end => |a| a,
        .fn_end => |f| f.arity + 1,
        .scope_end => |a| a,
        else => |node| std.debug.panic("unknown arity for {t}", .{node}),
    };
}

test {
    _ = Lexer;
    _ = Parser;
    _ = Vm;
    _ = Interner;
    _ = compiler;
}
