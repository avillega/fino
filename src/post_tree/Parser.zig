const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("../Lexer.zig");
const Interner = @import("../Interner.zig");

const Token = Lexer.Token;
const Parser = @This();
pub const Ast = []Node;

/// arity is stored in a u8, so a fn takes at most this many params
const max_params = 255;

gpa: Allocator,
src: [:0]const u8,
curr: Token,
peek: Token,
lexer: Lexer,
nodes: std.ArrayList(Node),
err: ?[]const u8,
interner: *Interner,

const Tag = enum(u8) {
    nil,
    const_int,
    atom,
    str_lit,
    arr_lit,
    record_lit,
    dec_var,
    dec_param,
    dec_capture,
    set_var,
    get_var,
    take_var,
    neg_expr,
    not_expr,
    add_expr,
    sub_expr,
    mul_expr,
    div_expr,
    eql_expr,
    not_eql_expr,
    lt_expr,
    lt_eql_expr,
    gt_expr,
    gt_eql_expr,
    call_expr,
    return_stmt,
    expr_stmt,
    get_index,
    set_index,

    // this are markers
    scope_begin,
    scope_end,

    fn_begin,
    fn_end,

    if_then,
    if_else,
    if_end,

    while_begin,
    while_do,
    while_end,

    for_do,
    for_end,
};

pub const Node = union(Tag) {
    nil,
    const_int: u24,
    atom: u24,
    str_lit: u24,
    arr_lit: u24, // number of expressions
    record_lit: u24, // number of pairs
    dec_var: u24,
    dec_param: u24,
    dec_capture: u24,
    set_var: u24,
    get_var: u24,
    take_var: u24,
    neg_expr,
    not_expr,
    add_expr,
    sub_expr,
    mul_expr,
    div_expr,
    eql_expr,
    not_eql_expr,
    lt_expr,
    lt_eql_expr,
    gt_expr,
    gt_eql_expr,
    call_expr: packed struct(u32) { id: u24, arg_c: u8 },
    return_stmt,
    expr_stmt,
    get_index,
    set_index: u24,

    // this are markers
    scope_begin,
    scope_end: u32, // display arity

    // replicate info mostly for debugging
    fn_begin: packed struct(u32) { id: u24, arity: u8 },
    fn_end: packed struct(u32) { id: u24, arity: u8 },

    if_then,
    if_else,
    if_end: u5, // display arity is 2 or 3 if has an else branch or not

    while_begin,
    while_do,
    while_end,

    for_do,
    for_end: u4, // number of captures

    pub fn VariantType(comptime tag: Tag) type {
        return @FieldType(@This(), @tagName(tag));
    }
};

const Error = error{
    UnexpectedToken,
    UnfinishedStmt,
    TooManyArgs,
    InvalidAssignmentTarget,
    TooManyCaptures,
} || Allocator.Error || std.fmt.ParseIntError;

pub fn init(gpa: Allocator, interner: *Interner) Parser {
    return .{
        .gpa = gpa,
        .interner = interner,
        .nodes = .empty,
        .err = null,
        // set in parse(), which owns stuff related to src
        .src = "",
        .lexer = undefined,
        .curr = undefined,
        .peek = undefined,
    };
}

/// only needed to reclaim the nodes of a parse that failed, a successful
/// parse hands its buffer to the caller
pub fn deinit(self: *Parser) void {
    self.nodes.deinit(self.gpa);
}

pub fn parse(self: *Parser, src: [:0]const u8) Error!Ast {
    self.src = src;
    self.lexer = .init(src);
    self.err = null;
    self.nodes.clearRetainingCapacity();

    // prime the curr and peek tokens by calling advance twice
    self.advanceTokens();
    self.advanceTokens();

    while (self.curr.tag != .eof) {
        try self.parseDecl();
    }
    return try self.nodes.toOwnedSlice(self.gpa);
}

fn advanceTokens(self: *Parser) void {
    self.curr = self.peek;
    self.peek = self.lexer.next();
}

fn parseDecl(self: *Parser) Error!void {
    while (self.curr.tag == .sep) {
        self.advanceTokens();
    }
    if (self.curr.tag == .eof) return;
    switch (self.curr.tag) {
        .kw_var => {
            self.advanceTokens(); // eat the kw_var
            const id = try self.internToken(.identifier);
            try self.expectToken(.eql);
            try self.parseExpr(0);
            try self.expectEndStmt();
            try self.addNode(.{ .dec_var = id });
        },
        .kw_fn => {
            self.advanceTokens(); // eat kw_fn
            const name_id = try self.internToken(.identifier);
            try self.expectToken(.oparen);

            var params: [max_params]u24 = undefined;
            var arity: u8 = 0;

            while (self.curr.tag != .cparen) {
                if (arity == max_params) return Error.TooManyArgs;
                if (arity != 0) try self.expectToken(.comma);

                // TODO:  check that this param is not already part of params
                params[arity] = try self.internToken(.identifier);
                arity += 1;
            }

            try self.expectToken(.cparen);

            try self.addNode(.{ .fn_begin = .{ .id = name_id, .arity = arity } });
            for (params[0..arity]) |id| {
                try self.addNode(.{ .dec_param = id });
            }

            try self.parseBlock();
            try self.addNode(.{ .fn_end = .{ .id = name_id, .arity = arity } });
        },
        else => try self.parseStmt(),
    }
}

fn parseStmt(self: *Parser) Error!void {
    switch (self.curr.tag) {
        .identifier => {
            // handle setting to an already declared variable
            if (self.peek.tag == .eql) {
                const id = try self.internToken(.identifier);
                self.advanceTokens(); // eat the eql
                const pos = self.nodes.items.len;

                try self.parseExpr(0);
                try self.expectEndStmt();

                var cnt: u32 = 0;
                var replace: usize = 0;
                for (self.nodes.items[pos..], pos..) |node, idx| {
                    if (node == .get_var and node.get_var == id) {
                        cnt += 1;
                        replace = idx;
                    }
                }

                if (cnt == 1) {
                    self.nodes.items[replace] = .{ .take_var = id };
                }
                try self.addNode(.{ .set_var = id });
                return;
            }

            const pos = self.nodes.items.len;
            try self.parseExpr(0);
            if (self.curr.tag == .eql) {
                // the expression at pos is an idx assignment
                if (!(self.nodes.items[pos] == .get_var and
                    self.nodes.items[self.nodes.items.len - 1] == .get_index))
                {
                    return error.InvalidAssignmentTarget;
                }

                _ = self.nodes.pop(); // remove the .get_index
                const var_id = self.nodes.orderedRemove(pos).get_var;
                // At this point the index expression is at the top

                self.advanceTokens(); // eat the .eql
                try self.parseExpr(0);
                try self.expectEndStmt();
                try self.addNode(.{ .set_index = var_id });
            } else {
                // otherwise handle it as a normal expression
                try self.expectEndStmt();
                try self.addNode(.expr_stmt);
            }
        },
        .obrace => try self.parseBlock(),
        .kw_if => try self.parseIf(),
        .kw_return => {
            self.advanceTokens(); // eat the kw_return
            if (self.curr.tag == .sep or self.curr.tag == .cbrace) {
                try self.addNode(.nil);
            } else {
                try self.parseExpr(0);
            }
            try self.expectEndStmt();
            try self.addNode(.return_stmt);
        },
        .kw_while => {
            self.advanceTokens(); // eat the while
            try self.addNode(.while_begin);
            try self.parseExpr(0); // parse the condition
            try self.addNode(.while_do);
            try self.parseBlock();
            try self.addNode(.while_end);
        },
        .kw_for => try self.parseFor(),
        else => {
            try self.parseExpr(0);
            try self.expectEndStmt();
            try self.addNode(.expr_stmt);
        },
    }
}

fn parseIf(self: *Parser) Error!void {
    self.advanceTokens(); // eat the if
    try self.parseExpr(0); // parse the condition
    try self.addNode(.if_then);
    try self.parseBlock();
    var arity: u4 = 3;
    if (self.curr.tag == .kw_else) {
        self.advanceTokens(); // eat the else
        try self.addNode(.if_else);
        arity += 2;
        if (self.curr.tag == .kw_if) {
            try self.parseIf();
        } else {
            try self.parseBlock();
        }
    }
    try self.addNode(.{ .if_end = arity });
}

fn parseBlock(self: *Parser) Error!void {
    try self.expectToken(.obrace); // eat the '{'

    try self.addNode(.scope_begin);
    var decl_count: u32 = 0;
    while (true) {
        while (self.curr.tag == .sep) self.advanceTokens();
        if (self.curr.tag == .cbrace or self.curr.tag == .eof) break;
        try self.parseDecl();
        decl_count += 1;
    }

    try self.expectToken(.cbrace); // eat the '}'
    try self.addNode(.{ .scope_end = decl_count });
}

fn parseFor(self: *Parser) Error!void {
    try self.expectToken(.kw_for); // eat the 'for'
    try self.expectToken(.oparen);

    while (self.curr.tag == .sep) self.advanceTokens();
    try self.parseExpr(0);
    while (self.curr.tag == .sep) self.advanceTokens();
    try self.expectToken(.cparen);
    try self.addNode(.for_do);

    try self.expectToken(.pipe);
    var capts: u4 = 0;
    while (capts < 2) { // only allow 1 or 2 captures
        while (self.curr.tag == .sep) self.advanceTokens();
        if (self.curr.tag == .pipe or self.curr.tag == .eof) break;
        if (capts > 0) try self.expectToken(.comma);
        const capture = try self.internToken(.identifier);
        try self.addNode(.{ .dec_capture = capture });
        capts += 1;
    }
    self.expectToken(.pipe) catch {
        return error.TooManyCaptures;
    };
    std.debug.assert(capts <= 2);

    while (self.curr.tag == .sep) self.advanceTokens();
    try self.parseBlock();
    try self.addNode(.{ .for_end = capts });
}

fn parseExpr(self: *Parser, min_prec: u16) Error!void {
    // left
    try self.parseFactor();

    while (binOp(self.curr.tag)) |op| {
        if (op.prec < min_prec) break;
        self.advanceTokens(); // eat the binary operation
        // right
        try self.parseExpr(op.prec + 1);
        try self.addNode(op.node);
    }
}

fn binOp(tag: Token.Tag) ?struct { node: Node, prec: u16 } {
    return switch (tag) {
        .eql_eql => .{ .node = .eql_expr, .prec = 40 },
        .bang_eql => .{ .node = .not_eql_expr, .prec = 40 },
        .lt => .{ .node = .lt_expr, .prec = 40 },
        .lt_eql => .{ .node = .lt_eql_expr, .prec = 40 },
        .gt => .{ .node = .gt_expr, .prec = 40 },
        .gt_eql => .{ .node = .gt_eql_expr, .prec = 40 },
        .plus => .{ .node = .add_expr, .prec = 45 },
        .minus => .{ .node = .sub_expr, .prec = 45 },
        .star => .{ .node = .mul_expr, .prec = 50 },
        .slash => .{ .node = .div_expr, .prec = 50 },
        else => null,
    };
}

fn parseFactor(self: *Parser) Error!void {
    switch (self.curr.tag) {
        .integer => {
            const n = try std.fmt.parseInt(i64, self.curr.lexeme(self.src), 10);
            const c = try self.interner.intern_i(n);
            try self.addNode(.{ .const_int = c });
            self.advanceTokens();
        },
        .kw_nil => {
            try self.addNode(.nil);
            self.advanceTokens();
        },
        .identifier => {
            const id = try self.internToken(.identifier);
            if (self.curr.tag == .oparen) {
                // handle as a call
                self.advanceTokens(); // eat the paren
                var arg_c: u8 = 0;
                while (self.curr.tag != .cparen) {
                    if (arg_c == std.math.maxInt(u8)) return Error.TooManyArgs;

                    if (arg_c != 0) try self.expectToken(.comma);
                    try self.parseExpr(0);
                    arg_c += 1;
                }
                try self.expectToken(.cparen);
                try self.addNode(.{ .call_expr = .{ .id = id, .arg_c = arg_c } });
            } else {
                // it is not a call just get the var
                try self.addNode(.{ .get_var = id });
            }
        },
        .str_lit => try self.addNode(.{ .str_lit = try self.internToken(.str_lit) }),
        .obracket => try self.parseArray(),
        .orecord => try self.parseRecord(),
        .oparen => {
            self.advanceTokens();
            try self.parseExpr(0);
            try self.expectToken(.cparen);
        },
        .bang => {
            self.advanceTokens();
            try self.parseFactor();
            try self.addNode(.not_expr);
        },
        .minus => {
            self.advanceTokens();
            try self.parseFactor();
            try self.addNode(.neg_expr);
        },
        else => {
            self.err = "Unexpected token. malformed factor";
            std.debug.print("got {t}\n", .{self.curr.tag});
            return error.UnexpectedToken;
        },
    }

    // parse indexing
    while (self.curr.tag == .obracket) {
        self.advanceTokens(); // eat the '['
        try self.parseExpr(0);
        try self.expectToken(.cbracket);
        try self.addNode(.get_index);
    }
}

fn parseArray(self: *Parser) Error!void {
    try self.expectToken(.obracket);
    var elem_count: u24 = 0;
    while (true) {
        while (self.curr.tag == .sep) self.advanceTokens();
        if (self.curr.tag == .cbracket or self.curr.tag == .eof) break;
        if (elem_count > 0) try self.expectToken(.comma);
        try self.parseExpr(0);
        elem_count += 1;
    }
    try self.expectToken(.cbracket);
    try self.addNode(.{ .arr_lit = elem_count });
}

fn parseRecord(self: *Parser) Error!void {
    try self.expectToken(.orecord);
    var pair_count: u24 = 0;
    while (true) {
        while (self.curr.tag == .sep) self.advanceTokens();
        if (self.curr.tag == .cbrace or self.curr.tag == .eof) break;
        if (pair_count > 0) try self.expectToken(.comma);
        try self.addNode(.{ .atom = try self.internToken(.atom) });
        try self.parseExpr(0);
        pair_count += 1;
    }
    try self.expectToken(.cbrace);
    try self.addNode(.{ .record_lit = pair_count });
}

fn addNode(self: *Parser, node: Node) Error!void {
    try self.nodes.append(self.gpa, node);
}

fn expectEndStmt(self: *Parser) !void {
    if (self.curr.tag == .cbrace) return;

    const t = self.curr;
    self.advanceTokens();
    switch (t.tag) {
        .sep, .eof => {},
        else => {
            std.debug.print("expected .sep or .eof, got {any}", .{t});
            self.err = "Unfinished statement";
            return error.UnfinishedStmt;
        },
    }
}

/// check that the current token is of the expected tag and eats the token
fn expectToken(self: *Parser, expected: Token.Tag) Error!void {
    const t = self.curr;
    self.advanceTokens();
    if (t.tag != expected) {
        return Error.UnexpectedToken;
    }
}

fn internToken(self: *Parser, expected: Token.Tag) Error!u24 {
    const t = self.curr;
    try self.expectToken(expected);
    return self.interner.intern_s(t.lexeme(self.src));
}

test "size of Node" {
    try std.testing.expectEqual(@sizeOf(Node), 8);
}

test "parse: precedence `1 + 2 * 1` parses as 1 + (2 * 1)" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse("1 + 2 * 1");
    defer gpa.free(ast);

    const expected = [_]Node{
        .{ .const_int = 0 },
        .{ .const_int = 1 },
        .{ .const_int = 0 },
        .mul_expr,
        .add_expr,
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: support both ; and endl as stmt terminators" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var p1 = Parser.init(gpa, &interner);
    const ast1 = try p1.parse("1 + 2 * 1");
    defer gpa.free(ast1);

    const expected = [_]Node{
        .{ .const_int = 0 },
        .{ .const_int = 1 },
        .{ .const_int = 0 },
        .mul_expr,
        .add_expr,
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast1);

    var p2 = Parser.init(gpa, &interner);
    const ast2 = try p2.parse("1 + 2 * 1;");
    defer gpa.free(ast2);
    try std.testing.expectEqualSlices(Node, ast1, ast2);
}

test "parse: using parens to force presedence" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse("(1 + 2) * 1");
    defer gpa.free(ast);

    const expected = [_]Node{
        .{ .const_int = 0 },
        .{ .const_int = 1 },
        .add_expr,
        .{ .const_int = 0 },
        .mul_expr,
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: unary operations correctly" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse("(1 + -2) * 1");
    defer gpa.free(ast);

    const expected = [_]Node{
        .{ .const_int = 0 },
        .{ .const_int = 1 },
        .neg_expr,
        .add_expr,
        .{ .const_int = 0 },
        .mul_expr,
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: simple block" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ {
        \\      var x = 5
        \\      x = 3; print(1 + 1)
        \\      print(2 + x)
        \\ }
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);

    const expected = [_]Node{
        .scope_begin,
        .{ .const_int = 0 },
        .{ .dec_var = 0 },
        .{ .const_int = 1 },
        .{ .set_var = 0 },
        .{ .const_int = 2 },
        .{ .const_int = 2 },
        .add_expr,
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .const_int = 3 },
        .{ .get_var = 0 },
        .add_expr,
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 4 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: simple function call" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ print(x)
        \\ print(1+2)
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);

    const expected = [_]Node{
        .{ .get_var = 1 },
        .{ .call_expr = .{ .id = 0, .arg_c = 1 } },
        .expr_stmt,
        .{ .const_int = 0 },
        .{ .const_int = 1 },
        .add_expr,
        .{ .call_expr = .{ .id = 0, .arg_c = 1 } },
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: simple if" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ if x == 0 {
        \\      var x = 5
        \\      print(x)
        \\ }
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);

    const expected = [_]Node{
        .{ .get_var = 0 },
        .{ .const_int = 0 },
        .eql_expr,
        .if_then,
        .scope_begin,
        .{ .const_int = 1 },
        .{ .dec_var = 0 },
        .{ .get_var = 0 },
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 2 },
        .{ .if_end = 3 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}
test "parse: simple if/else" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ if x == 0 {
        \\      var x = 5
        \\      print(x)
        \\ } else {
        \\    var y = 5
        \\    print(y)
        \\}
        \\
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);

    const expected = [_]Node{
        .{ .get_var = 0 },
        .{ .const_int = 0 },
        .eql_expr,
        .if_then,
        .scope_begin,
        .{ .const_int = 1 },
        .{ .dec_var = 0 },
        .{ .get_var = 0 },
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 2 },
        .if_else,
        .scope_begin,
        .{ .const_int = 1 },
        .{ .dec_var = 2 },
        .{ .get_var = 2 },
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 2 },
        .{ .if_end = 5 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: simple if/elseif/else" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ if x == 0 {
        \\      var x = 5
        \\      print(x)
        \\ } else if y == 0 {
        \\    var y = 5
        \\    print(y)
        \\ } else {
        \\    var z = 5
        \\    print(z)
        \\}
        \\
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);

    const expected = [_]Node{
        .{ .get_var = 0 },
        .{ .const_int = 0 },
        .eql_expr,
        .if_then,
        .scope_begin,
        .{ .const_int = 1 },
        .{ .dec_var = 0 },
        .{ .get_var = 0 },
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 2 },
        .if_else,
        .{ .get_var = 2 },
        .{ .const_int = 0 },
        .eql_expr,
        .if_then,
        .scope_begin,
        .{ .const_int = 1 },
        .{ .dec_var = 2 },
        .{ .get_var = 2 },
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 2 },
        .if_else,
        .scope_begin,
        .{ .const_int = 1 },
        .{ .dec_var = 3 },
        .{ .get_var = 3 },
        .{ .call_expr = .{ .id = 1, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 2 },
        .{ .if_end = 5 },
        .{ .if_end = 5 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}
test "parse: simple string literal" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ var a = "my_string/lit"
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);
    const expected = [_]Node{
        .{ .str_lit = 1 },
        .{ .dec_var = 0 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
    try std.testing.expectEqualStrings("my_string/lit", try interner.get_s(1));
}

test "parse: simple array literal" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ var a = [x, y ,z, w]
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);
    const expected = [_]Node{
        .{ .get_var = 1 },
        .{ .get_var = 2 },
        .{ .get_var = 3 },
        .{ .get_var = 4 },
        .{ .arr_lit = 4 },
        .{ .dec_var = 0 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: simple array index get" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ a[10]
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);
    const expected = [_]Node{
        .{ .get_var = 0 },
        .{ .const_int = 0 },
        .get_index,
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: simple array index set" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ a[10] = 2
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);
    const expected = [_]Node{
        .{ .const_int = 0 },
        .{ .const_int = 1 },
        .{ .set_index = 0 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: array index error" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ a[10] + 10 = 2
    ;
    var parser = Parser.init(gpa, &interner);
    defer parser.deinit();
    try std.testing.expectError(error.InvalidAssignmentTarget, parser.parse(src));
}

test "parse: record" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ .{ :a "hello", :world "another"}
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);
    const expected = [_]Node{
        .{ .atom = 0 },
        .{ .str_lit = 1 },
        .{ .atom = 2 },
        .{ .str_lit = 3 },
        .{ .record_lit = 2 },
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}

test "parse: for" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ for (record) |k, v| {
        \\    print(k)   
        \\ }
    ;
    var parser = Parser.init(gpa, &interner);
    const ast = try parser.parse(src);
    defer gpa.free(ast);
    const expected = [_]Node{
        .{ .get_var = 0 },
        .for_do,
        .{ .dec_capture = 1 },
        .{ .dec_capture = 2 },
        .scope_begin,
        .{ .get_var = 1 },
        .{ .call_expr = .{ .id = 3, .arg_c = 1 } },
        .expr_stmt,
        .{ .scope_end = 1 },
        .{ .for_end = 2 },
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}
