const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("../Lexer.zig");
const Interner = @import("../Interner.zig");

const Token = Lexer.Token;
const Parser = @This();
pub const Ast = []Node;

src: [:0]const u8,
curr: Token,
peek: Token,
lexer: Lexer,
nodes: std.ArrayListUnmanaged(Node),
err: ?[]const u8,
interner: *Interner,

const Tag = enum(u8) {
    nil,
    const_int,
    str_lit,
    arr_lit,
    dec_var,
    dec_param,
    set_var,
    get_var,
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
};

pub const Node = union(Tag) {
    nil,
    const_int: u24,
    str_lit: u24,
    arr_lit: u24, // number of expressions
    dec_var: u24,
    dec_param: u24,
    set_var: u24,
    get_var: u24,
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

    /// Helper function to extract the type of a specific union field at compile-time
    pub fn VariantType(comptime tag: Tag) type {
        return @FieldType(@This(), @tagName(tag));
    }
};

const Error = error{
    UnexpectedToken,
    UnfinishedStmt,
    TooManyArgs,
} || Allocator.Error || std.fmt.ParseIntError;

pub fn init(src: [:0]const u8, interner: *Interner) Parser {
    var parser: Parser = .{
        .src = src,
        .lexer = Lexer.init(src),
        .nodes = .empty,
        .err = null,
        .curr = undefined,
        .peek = undefined,
        .interner = interner,
    };

    // prime the curr and peek tokens by calling advance twice
    parser.advanceTokens();
    parser.advanceTokens();
    return parser;
}

pub fn parse(self: *Parser, gpa: Allocator) Error!Ast {
    while (self.curr.tag != .eof) {
        try self.parseDecl(gpa);
    }
    return try self.nodes.toOwnedSlice(gpa);
}

fn advanceTokens(self: *Parser) void {
    self.curr = self.peek;
    self.peek = self.lexer.next();
}

fn parseDecl(self: *Parser, gpa: Allocator) Error!void {
    while (self.curr.tag == .sep) {
        self.advanceTokens();
    }
    if (self.curr.tag == .eof) return;
    switch (self.curr.tag) {
        .kw_var => {
            self.advanceTokens(); // eat the kw_var
            const id = try self.parseIdentifier();
            _ = try self.expectToken(.eql);
            try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            try self.addNode(gpa, .{ .dec_var = id });
        },
        .kw_fn => {
            self.advanceTokens(); // eat kw_fn
            const name_id = try self.parseIdentifier();
            _ = try self.expectToken(.oparen);

            var args_names: std.ArrayList(u24) = try .initCapacity(gpa, 255);
            defer args_names.deinit(gpa);

            while (self.curr.tag != .cparen) {
                if (args_names.items.len == 255) {
                    return Error.TooManyArgs;
                }

                if (args_names.items.len != 0) {
                    _ = try self.expectToken(.comma);
                }

                // TODO:  check that this arg_id is not already part of the args_names
                const arg_id = try self.parseIdentifier();
                args_names.appendAssumeCapacity(arg_id);
            }

            _ = try self.expectToken(.cparen);

            try self.addNode(gpa, .{ .fn_begin = .{ .id = name_id, .arity = @intCast(args_names.items.len) } });
            for (args_names.items) |id| {
                try self.addNode(gpa, .{ .dec_param = id });
            }

            try self.parseBlock(gpa);
            try self.addNode(gpa, .{ .fn_end = .{ .id = name_id, .arity = @intCast(args_names.items.len) } });
        },
        else => try self.parseStmt(gpa),
    }
}

fn parseStmt(self: *Parser, gpa: Allocator) Error!void {
    switch (self.curr.tag) {
        .identifier => {
            // handle setting to an already declared variable
            if (self.peek.tag == .eql) {
                const id = try self.parseIdentifier();
                self.advanceTokens(); // eat the eql

                try self.parseExpr(gpa, 0);
                try self.expectEndStmt();
                try self.addNode(gpa, .{ .set_var = id });
                return;
            }

            // otherwise handle it as a normal expression
            try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            try self.addNode(gpa, .expr_stmt);
        },
        .obrace => {
            try self.parseBlock(gpa);
        },
        .kw_return => {
            self.advanceTokens(); // eat the kw_return
            if (self.curr.tag == .sep or self.curr.tag == .cbrace) {
                try self.addNode(gpa, .nil);
            } else {
                try self.parseExpr(gpa, 0);
            }
            try self.expectEndStmt();
            try self.addNode(gpa, .return_stmt);
        },
        .kw_if => {
            try self.parseIf(gpa);
        },
        .kw_while => {
            self.advanceTokens(); // eat the while
            try self.addNode(gpa, .while_begin);
            try self.parseExpr(gpa, 0); // parse the condition
            try self.addNode(gpa, .while_do);
            try self.parseBlock(gpa);
            try self.addNode(gpa, .while_end);
        },
        else => {
            try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            try self.addNode(gpa, .expr_stmt);
        },
    }
}

fn parseIf(self: *Parser, gpa: Allocator) Error!void {
    self.advanceTokens(); // eat the if
    try self.parseExpr(gpa, 0); // parse the condition
    try self.addNode(gpa, .if_then);
    try self.parseBlock(gpa);
    var arity: u4 = 3;
    if (self.curr.tag == .kw_else) {
        self.advanceTokens(); // eat the else
        try self.addNode(gpa, .if_else);
        arity += 2;
        if (self.curr.tag == .kw_if) {
            try self.parseIf(gpa);
        } else {
            try self.parseBlock(gpa);
        }
    }
    try self.addNode(gpa, .{ .if_end = arity });
}

fn parseBlock(self: *Parser, gpa: Allocator) Error!void {
    _ = try self.expectToken(.obrace); // eat the '{'

    try self.addNode(gpa, .scope_begin);
    var decl_count: u32 = 0;
    while (true) {
        while (self.curr.tag == .sep) self.advanceTokens();
        if (self.curr.tag == .cbrace or self.curr.tag == .eof) break;
        try self.parseDecl(gpa);
        decl_count += 1;
    }

    _ = try self.expectToken(.cbrace); // eat the '}'
    try self.addNode(gpa, .{ .scope_end = decl_count });
}

fn parseExpr(self: *Parser, gpa: Allocator, min_prec: u16) Error!void {
    // left
    try self.parseFactor(gpa);

    while (isBinOp(self.curr) and precedence(self.curr) >= min_prec) {
        const bin_t = self.curr;
        const op_node: Node = switch (bin_t.tag) {
            .plus => .add_expr,
            .minus => .sub_expr,
            .slash => .div_expr,
            .star => .mul_expr,
            .eql_eql => .eql_expr,
            .bang_eql => .not_eql_expr,
            .lt => .lt_expr,
            .lt_eql => .lt_eql_expr,
            .gt_eql => .gt_eql_expr,
            .gt => .gt_expr,
            else => std.debug.panic("Unexpected token {s}", .{self.curr.lexeme(self.src)}),
        };
        self.advanceTokens(); // eat the binary operation
        // right
        try self.parseExpr(gpa, precedence(bin_t) + 1);
        try self.addNode(gpa, op_node);
    }
}

fn parseFactor(self: *Parser, gpa: Allocator) Error!void {
    switch (self.curr.tag) {
        .integer => {
            const n = try std.fmt.parseInt(i64, self.curr.lexeme(self.src), 10);
            const c = try self.interner.intern_i(n);
            try self.addNode(gpa, .{ .const_int = c });
            self.advanceTokens();
        },
        .kw_nil => {
            try self.addNode(gpa, .nil);
            self.advanceTokens();
        },
        .identifier => {
            const id = try self.parseIdentifier();
            if (self.curr.tag == .oparen) {
                // handle as a call
                self.advanceTokens(); // eat the paren
                var arg_c: u8 = 0;
                while (self.curr.tag != .cparen) {
                    if (arg_c == std.math.maxInt(u8)) return Error.TooManyArgs;

                    if (arg_c != 0) _ = try self.expectToken(.comma);
                    try self.parseExpr(gpa, 0);
                    arg_c += 1;
                }
                _ = try self.expectToken(.cparen);
                try self.addNode(gpa, .{ .call_expr = .{ .id = id, .arg_c = arg_c } });
            } else {
                // it is not a call just get the var
                try self.addNode(gpa, .{ .get_var = id });
            }
        },
        .str_lit => {
            const id = try self.internStrLit();
            try self.addNode(gpa, .{ .str_lit = id });
        },
        .obracket => {
            try self.parseArray(gpa);
        },
        .oparen => {
            self.advanceTokens();
            try self.parseExpr(gpa, 0);
            _ = try self.expectToken(.cparen);
        },
        .bang => {
            self.advanceTokens();
            try self.parseFactor(gpa);
            try self.addNode(gpa, .not_expr);
        },
        .minus => {
            self.advanceTokens();
            try self.parseFactor(gpa);
            try self.addNode(gpa, .neg_expr);
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
        try self.parseExpr(gpa, 0);
        _ = try self.expectToken(.cbracket);
        try self.addNode(gpa, .get_index);
    }
}

fn parseIdentifier(self: *Parser) !u24 {
    const ident_token = try self.expectToken(.identifier);
    const ident = ident_token.lexeme(self.src);
    return try self.interner.intern_s(ident);
}

fn internStrLit(self: *Parser) !u24 {
    const str_token = try self.expectToken(.str_lit);
    const lit = str_token.lexeme(self.src);
    return try self.interner.intern_s(lit);
}

fn parseArray(self: *Parser, gpa: Allocator) !void {
    _ = try self.expectToken(.obracket);
    var elem_count: u24 = 0;
    while (true) {
        while (self.curr.tag == .sep) self.advanceTokens();
        if (self.curr.tag == .cbracket or self.curr.tag == .eof) break;
        if (elem_count > 0) _ = try self.expectToken(.comma);
        try self.parseExpr(gpa, 0);
        elem_count += 1;
    }
    _ = try self.expectToken(.cbracket);
    try self.addNode(gpa, .{ .arr_lit = elem_count });
}

fn addNode(self: *Parser, gpa: Allocator, node: Node) !void {
    try self.nodes.append(gpa, node);
}

fn isBinOp(tok: Token) bool {
    return switch (tok.tag) {
        .plus,
        .minus,
        .star,
        .slash,
        .lt,
        .gt,
        .eql_eql,
        .bang_eql,
        .lt_eql,
        .gt_eql,
        => true,
        else => false,
    };
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
fn expectToken(self: *Parser, expected: Token.Tag) Error!Token {
    const t = self.curr;
    self.advanceTokens();
    if (t.tag != expected) {
        return Error.UnexpectedToken;
    }
    return t;
}

fn precedence(tok: Token) u16 {
    return switch (tok.tag) {
        .eql_eql, .bang_eql, .lt_eql, .gt_eql, .gt, .lt => 40,
        .plus, .minus => 45,
        .slash, .star, .mod => 50,
        else => std.debug.panic("Unexpected token {t}", .{tok.tag}),
    };
}

test "size of Node" {
    try std.testing.expectEqual(@sizeOf(Node), 8);
}

test "parse: precedence `1 + 2 * 1` parses as 1 + (2 * 1)" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init("1 + 2 * 1", &interner);
    const ast = try parser.parse(gpa);
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
    var p1 = Parser.init("1 + 2 * 1", &interner);
    const ast1 = try p1.parse(gpa);
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

    var p2 = Parser.init("1 + 2 * 1;", &interner);
    const ast2 = try p2.parse(gpa);
    defer gpa.free(ast2);
    try std.testing.expectEqualSlices(Node, ast1, ast2);
}

test "parse: using parens to force presedence" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init("(1 + 2) * 1", &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init("(1 + -2) * 1", &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
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
    var parser = Parser.init(src, &interner);
    const ast = try parser.parse(gpa);
    defer gpa.free(ast);
    const expected = [_]Node{
        .{ .get_var = 0 },
        .{ .const_int = 0 },
        .get_index,
        .expr_stmt,
    };
    try std.testing.expectEqualSlices(Node, &expected, ast);
}
