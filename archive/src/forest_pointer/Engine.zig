const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Parser = @import("Parser.zig");
const Lexer = @import("../Lexer.zig");
const Vm = @import("../Vm.zig");
const Interner = @import("../Interner.zig");

const compiler = @import("compiler.zig");

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
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var parser: Parser = .init(src, &self.interner);
    const ast = parser.parse(arena.allocator()) catch |err| {
        const serr = parser.err orelse "";
        try self.w.print("{t} {s}\n", .{ err, serr });
        return;
    };

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
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var parser = Parser.init(src, &self.interner);

    const ast = try parser.parse(arena.allocator());

    try compiler.collectFns(self.gpa, ast, &self.fn_map, &self.fn_table);
    _ = try compiler.compile(self.gpa, ast, &self.insts, &self.fn_map, self.fn_table.items);
    return;
}

const Size = struct { bytes: usize = 0, nodes: usize = 0 };

fn measure(node: *const Parser.Node, acc: *Size) void {
    acc.bytes += @sizeOf(Parser.Node);
    acc.nodes += 1;
    switch (node.*) {
        .nil, .const_int, .get_var, .dec_param => {},
        .dec_var, .set_var => |v| measure(v.expr, acc),
        .neg_expr, .not_expr, .print_stmt, .return_stmt, .expr_stmt => |u| measure(u.expr, acc),
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
        => |b| {
            measure(b.lhs, acc);
            measure(b.rhs, acc);
        },
        .root, .scope => |block| {
            acc.bytes += block.len * @sizeOf(*Parser.Node);
            for (block) |n| measure(n, acc);
        },
        .call_expr => |c| {
            acc.bytes += c.args.len * @sizeOf(*Parser.Node);
            for (c.args) |n| measure(n, acc);
        },
        .fndef => |f| {
            acc.bytes += f.body.len * @sizeOf(*Parser.Node);
            for (f.body) |n| measure(n, acc);
        },
        .if_stmt => |i| {
            measure(i.cond, acc);
            measure(i.then_branch, acc);
            if (i.else_branch) |e| measure(e, acc);
        },
        .while_stmt => |wl| {
            measure(wl.cond, acc);
            measure(wl.body, acc);
        },
    }
}

pub fn printAstSize(self: *Engine, src: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var parser = Parser.init(src, &self.interner);
    const ast = try parser.parse(arena.allocator());

    var size: Size = .{};
    measure(ast, &size);
    try self.w.print("ast: {d} nodes, {d}B ({d}B/node + child slices)\n", .{ size.nodes, size.bytes, @sizeOf(Parser.Node) });
    try self.w.flush();
}

pub fn printAstFlat(self: *Engine, src: [:0]const u8) !void {
    _ = self; // autofix
    _ = src; // autofix
    @panic("Unsupported for forest pointer version");
}

pub fn printAstTree(self: *Engine, src: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var parser = Parser.init(src, &self.interner);
    const ast = try parser.parse(arena.allocator());
    try printNode(self.w, &self.interner, ast, 0);
    try self.w.flush();
}

fn printNode(w: *Io.Writer, interner: *Interner, node: *Parser.Node, depth: u32) !void {
    for (0..depth) |_| {
        try w.writeAll("│ ");
    }

    switch (node.*) {
        .nil => {
            try w.writeAll("nil\n");
        },
        .const_int => |id| {
            try w.print("{t} {d}\n", .{ node.*, try interner.get_i(id) });
        },
        .root, .scope => |block| {
            try w.print("{t}\n", .{node.*});
            for (block) |n| {
                try printNode(w, interner, n, depth + 1);
            }
        },
        .get_var, .dec_param => |id| {
            try w.print("{t} {s}\n", .{ node.*, try interner.get_s(id) });
        },
        .dec_var, .set_var => |v| {
            try w.print("{t} {s}\n", .{ node.*, try interner.get_s(v.id) });
            try printNode(w, interner, v.expr, depth + 1);
        },
        .neg_expr, .not_expr, .print_stmt, .return_stmt, .expr_stmt => |unary| {
            try w.print("{t}\n", .{node.*});
            try printNode(w, interner, unary.expr, depth + 1);
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
            try w.print("{t}\n", .{node.*});
            try printNode(w, interner, binary.lhs, depth + 1);
            try printNode(w, interner, binary.rhs, depth + 1);
        },
        .call_expr => |call| {
            try w.print("{t} {s}/{d}\n", .{ node.*, try interner.get_s(call.id), call.args.len });
            for (call.args) |n| {
                try printNode(w, interner, n, depth + 1);
            }
        },
        .fndef => |fnd| {
            try w.print("{t} {s}/{d}\n", .{ node.*, try interner.get_s(fnd.id), fnd.arity });
            for (fnd.body) |n| {
                try printNode(w, interner, n, depth + 1);
            }
        },
        .if_stmt => |if_s| {
            try w.print("{t}\n", .{node.*});
            try printNode(w, interner, if_s.cond, depth + 1);
            try printNode(w, interner, if_s.then_branch, depth + 1);
            if (if_s.else_branch) |b| {
                try printNode(w, interner, b, depth + 1);
            }
        },
        .while_stmt => |while_s| {
            try w.print("{t}\n", .{node.*});
            try printNode(w, interner, while_s.cond, depth + 1);
            try printNode(w, interner, while_s.body, depth + 1);
        },
    }
}

pub fn printInsts(self: *Engine, src: [:0]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    var parser: Parser = .init(src, &self.interner);
    const ast = parser.parse(arena.allocator()) catch |err| {
        const serr = parser.err orelse "";
        try self.w.print("{t} {s}\n", .{ err, serr });
        return;
    };

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

test {
    _ = Lexer;
    _ = Parser;
    _ = Vm;
    _ = Interner;
}
