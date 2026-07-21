//! Debug views of the front half of the pipeline. Each fn is self-contained
//! — it parses with its own local interner and needs nothing from the
//! session.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const Lexer = @import("../Lexer.zig");
const Interner = @import("../Interner.zig");

pub fn printTokens(w: *Io.Writer, src: [:0]const u8) !void {
    var lex = Lexer.init(src);
    try Lexer.printTokens(w, &lex);
    try w.flush();
}

pub fn printAstSize(w: *Io.Writer, gpa: Allocator, src: [:0]const u8) !void {
    var interner: Interner = .init(gpa);
    defer interner.deinit();
    var parser: Parser = .init(src, &interner);
    const ast = try parser.parse(gpa);
    defer gpa.free(ast);

    const bytes = ast.len * @sizeOf(Parser.Node);
    try w.print("ast: {d} nodes, {d}B ({d}B/node)\n", .{ ast.len, bytes, @sizeOf(Parser.Node) });
    try w.flush();
}

pub fn printAstFlat(w: *Io.Writer, gpa: Allocator, src: [:0]const u8) !void {
    defer w.flush() catch unreachable;
    var interner: Interner = .init(gpa);
    defer interner.deinit();
    var parser: Parser = .init(src, &interner);
    const ast = parser.parse(gpa) catch |err| {
        const serr = parser.err orelse "";
        try w.print("{t} {s}\n", .{ err, serr });
        try w.print("printing partial parsed list\n", .{});
        try printFlat(w, parser.nodes.items);
        return;
    };
    defer gpa.free(ast);
    try printFlat(w, ast);
}

pub fn printAstTree(w: *Io.Writer, gpa: Allocator, src: [:0]const u8) !void {
    defer w.flush() catch unreachable;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const alloc = arena.allocator();
    defer arena.deinit();

    var interner: Interner = .init(gpa);
    defer interner.deinit();
    var parser: Parser = .init(src, &interner);
    const ast = parser.parse(alloc) catch |err| {
        const serr = parser.err orelse "";
        try w.print("{t} {s}\n", .{ err, serr });
        try w.print("printing partial parsed list\n", .{});
        try printFlat(w, parser.nodes.items);
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
                _ = try w.write("│ ");
            }

            try writeLabel(w, &interner, item.node);
            _ = try w.write("\n");
        }
    }
}

fn printFlat(w: *Io.Writer, ast: Parser.Ast) !void {
    for (ast) |node| {
        try w.print("{any}\n", .{node});
    }
}

fn writeLabel(w: *Io.Writer, interner: *Interner, n: Parser.Node) !void {
    switch (n) {
        .const_int => |i| try w.print("{t} {d}", .{ n, try interner.get_i(i) }),
        .set_var,
        .dec_var,
        .dec_param,
        .get_var,
        => |i| try w.print("{t} {s}", .{ n, try interner.get_s(i) }),
        .str_lit => |i| try w.print("{t} \"{s}\"", .{ n, try interner.get_s(i) }),
        .fn_end => |f| try w.print("fn {s}", .{try interner.get_s(f.id)}),
        .scope_end => try w.print("block", .{}),
        .call_expr => |c| try w.print("call {s}/{d}", .{ try interner.get_s(c.id), c.arg_c }),
        .if_then => try w.writeAll("then"),
        .if_else => try w.writeAll("else"),
        .if_end => try w.writeAll("if"),
        .while_do => try w.writeAll("cond"),
        .while_end => try w.writeAll("while"),
        else => |node| try w.print("{t}", .{node}),
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
        .str_lit,
        => 0,
        .set_var,
        .dec_var,
        .neg_expr,
        .not_expr,

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

test "printAstTree: every construct" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    const src =
        \\var g = 1
        \\fn add(a, b) {
        \\    var c = a + b * 2 - (6 - 7)
        \\    return c
        \\}
        \\add(1, 2)
        \\while g < 10 {
        \\    if g == 2 {
        \\        print(add(g, -1))
        \\    } else if g > 5 {
        \\        print(!0)
        \\    } else {
        \\        g = g + 1
        \\        var s = "my_str/lit"
        \\    }
        \\}
        \\{
        \\    print(g)
        \\}
    ;

    const expected =
        \\dec_var g
        \\│ const_int 1
        \\fn add
        \\│ dec_param a
        \\│ dec_param b
        \\│ block
        \\│ │ dec_var c
        \\│ │ │ sub_expr
        \\│ │ │ │ add_expr
        \\│ │ │ │ │ get_var a
        \\│ │ │ │ │ mul_expr
        \\│ │ │ │ │ │ get_var b
        \\│ │ │ │ │ │ const_int 2
        \\│ │ │ │ sub_expr
        \\│ │ │ │ │ const_int 6
        \\│ │ │ │ │ const_int 7
        \\│ │ return_stmt
        \\│ │ │ get_var c
        \\expr_stmt
        \\│ call add/2
        \\│ │ const_int 1
        \\│ │ const_int 2
        \\while
        \\│ cond
        \\│ │ lt_expr
        \\│ │ │ get_var g
        \\│ │ │ const_int 10
        \\│ block
        \\│ │ if
        \\│ │ │ eql_expr
        \\│ │ │ │ get_var g
        \\│ │ │ │ const_int 2
        \\│ │ │ then
        \\│ │ │ block
        \\│ │ │ │ expr_stmt
        \\│ │ │ │ │ call print/1
        \\│ │ │ │ │ │ call add/2
        \\│ │ │ │ │ │ │ get_var g
        \\│ │ │ │ │ │ │ neg_expr
        \\│ │ │ │ │ │ │ │ const_int 1
        \\│ │ │ else
        \\│ │ │ if
        \\│ │ │ │ gt_expr
        \\│ │ │ │ │ get_var g
        \\│ │ │ │ │ const_int 5
        \\│ │ │ │ then
        \\│ │ │ │ block
        \\│ │ │ │ │ expr_stmt
        \\│ │ │ │ │ │ call print/1
        \\│ │ │ │ │ │ │ not_expr
        \\│ │ │ │ │ │ │ │ const_int 0
        \\│ │ │ │ else
        \\│ │ │ │ block
        \\│ │ │ │ │ set_var g
        \\│ │ │ │ │ │ add_expr
        \\│ │ │ │ │ │ │ get_var g
        \\│ │ │ │ │ │ │ const_int 1
        \\│ │ │ │ │ dec_var s
        \\│ │ │ │ │ │ str_lit "my_str/lit"
        \\block
        \\│ expr_stmt
        \\│ │ call print/1
        \\│ │ │ get_var g
        \\
    ;

    try printAstTree(&w, gpa, src);
    try std.testing.expectEqualStrings(expected, w.buffered());
}
