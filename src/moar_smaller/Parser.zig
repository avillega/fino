const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("../Lexer.zig");
const Interner = @import("../Interner.zig");

const Token = Lexer.Token;
const Parser = @This();
pub const Ast = struct {
    tags: []Tag,
    nodes: []Node,

    pub fn deinit(self: *Ast, gpa: Allocator) void {
        gpa.free(self.tags);
        gpa.free(self.nodes);
    }
};

src: [:0]const u8,
curr: Token,
peek: Token,
lexer: Lexer,
tags: std.ArrayList(Tag),
nodes: std.ArrayListUnmanaged(Node),
err: ?[]const u8,
interner: *Interner,

pub const Tag = enum(u8) {
    nil,
    const_int,
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
    nql_expr,
    lt_expr,
    lql_expr,
    gt_expr,
    gql_expr,
    call_expr,
    print_stmt,
    return_stmt,
    expr_stmt,

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

pub const Node = union {
    nil: void,
    const_int: u24,
    dec_var: u24,
    dec_param: u24,
    set_var: u24,
    get_var: u24,
    neg_expr: void,
    not_expr: void,
    add_expr: void,
    sub_expr: void,
    mul_expr: void,
    div_expr: void,
    eql_expr: void,
    nql_expr: void,
    lt_expr: void,
    lql_expr: void,
    gt_expr: void,
    gql_expr: void,
    call_expr: packed struct(u32) { id: u24, arg_c: u8 },
    print_stmt: void,
    return_stmt: void,
    expr_stmt: void,

    // this are markers
    scope_begin: void,
    scope_end: u32, // display arity

    // replicate info mostly for debugging
    fn_begin: packed struct(u32) { id: u24, arity: u8 },
    fn_end: packed struct(u32) { id: u24, arity: u8 },

    if_then: void,
    if_else: void,
    if_end: u5, // display arity is 2 or 3 if has an else branch or not

    while_begin: void,
    while_do: void,
    while_end: void,
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
        .tags = .empty,
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

    return .{
        .nodes = try self.nodes.toOwnedSlice(gpa),
        .tags = try self.tags.toOwnedSlice(gpa),
    };
}

fn advanceTokens(self: *Parser) void {
    self.curr = self.peek;
    self.peek = self.lexer.next();
}

fn parseDecl(self: *Parser, gpa: Allocator) Error!void {
    while (self.curr.tag == .endl or self.curr.tag == .semi) {
        self.advanceTokens();
    }
    if (self.curr.tag == .eof) return;
    switch (self.curr.tag) {
        .kw_var => {
            self.advanceTokens(); // eat the kw_var
            const global = try self.parseIdentifier();
            _ = try self.expectToken(.eql);
            try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            try self.addNode(gpa, .dec_var, global);
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

            try self.addNode(gpa, .fn_begin, .{ .id = name_id, .arity = @intCast(args_names.items.len) });
            for (args_names.items) |id| {
                try self.addNode(gpa, .dec_param, id);
            }

            try self.parseBlock(gpa);
            try self.addNode(gpa, .fn_end, .{ .id = name_id, .arity = @intCast(args_names.items.len) });
        },
        else => try self.parseStmt(gpa),
    }
}

fn parseStmt(self: *Parser, gpa: Allocator) Error!void {
    switch (self.curr.tag) {
        .kw_print => {
            self.advanceTokens(); // eat the kw_print
            try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            try self.addNode(gpa, .print_stmt, {});
        },
        .identifier => {
            // handle setting to an already declared variable
            if (self.peek.tag == .eql) {
                const ident = self.curr.lexeme(self.src);
                const id = try self.interner.intern_s(ident);

                self.advanceTokens(); // eat the ident
                self.advanceTokens(); // eat the eql

                try self.parseExpr(gpa, 0);
                try self.expectEndStmt();
                try self.addNode(gpa, .set_var, id);
                return;
            }

            // otherwise handle it as a normal expression
            try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            try self.addNode(gpa, .expr_stmt, {});
        },
        .obrace => {
            try self.parseBlock(gpa);
        },
        .kw_return => {
            self.advanceTokens(); // eat the kw_return
            if (self.curr.tag == .semi or self.curr.tag == .endl) {
                self.advanceTokens(); // eat the separator
                try self.addNode(gpa, .nil, {});
            } else {
                try self.parseExpr(gpa, 0);
                try self.expectEndStmt();
            }
            try self.addNode(gpa, .return_stmt, {});
        },
        .kw_if => {
            try self.parseIf(gpa);
        },
        .kw_while => {
            self.advanceTokens(); // eat the while
            try self.addNode(gpa, .while_begin, {});
            try self.parseExpr(gpa, 0); // parse the condition
            try self.addNode(gpa, .while_do, {});
            try self.parseBlock(gpa);
            try self.addNode(gpa, .while_end, {});
        },
        else => {
            try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            try self.addNode(gpa, .expr_stmt, {});
        },
    }
}

fn parseIf(self: *Parser, gpa: Allocator) Error!void {
    self.advanceTokens(); // eat the if
    try self.parseExpr(gpa, 0); // parse the condition
    try self.addNode(gpa, .if_then, {});
    try self.parseBlock(gpa);
    var arity: u4 = 3;
    if (self.curr.tag == .kw_else) {
        self.advanceTokens(); // eat the else
        try self.addNode(gpa, .if_else, {});
        arity += 2;
        if (self.curr.tag == .kw_if) {
            try self.parseIf(gpa);
        } else {
            try self.parseBlock(gpa);
        }
    }
    try self.addNode(gpa, .if_end, arity);
}

fn parseBlock(self: *Parser, gpa: Allocator) Error!void {
    _ = try self.expectToken(.obrace); // eat the '{'

    try self.addNode(gpa, .scope_begin, {});
    var decl_count: u32 = 0;
    while (true) {
        while (self.curr.tag == .endl or self.curr.tag == .semi) self.advanceTokens();
        if (self.curr.tag == .cbrace or self.curr.tag == .eof) break;
        try self.parseDecl(gpa);
        decl_count += 1;
    }

    _ = try self.expectToken(.cbrace); // eat the '}'
    try self.addNode(gpa, .scope_end, decl_count);
}

fn parseExpr(self: *Parser, gpa: Allocator, min_prec: u16) Error!void {
    // left
    try self.parseFactor(gpa);

    while (isBinOp(self.curr) and precedence(self.curr) >= min_prec) {
        const bin_t = self.curr;
        self.advanceTokens(); // eat the binary operation
        // right
        try self.parseExpr(gpa, precedence(bin_t) + 1);

        // Add bin_op
        switch (bin_t.tag) {
            .plus => try self.addNode(gpa, .add_expr, {}),
            .minus => try self.addNode(gpa, .sub_expr, {}),
            .slash => try self.addNode(gpa, .div_expr, {}),
            .star => try self.addNode(gpa, .mul_expr, {}),
            .eql_eql => try self.addNode(gpa, .eql_expr, {}),
            .bang_eql => try self.addNode(gpa, .nql_expr, {}),
            .lt => try self.addNode(gpa, .lt_expr, {}),
            .lt_eql => try self.addNode(gpa, .lql_expr, {}),
            .gt_eql => try self.addNode(gpa, .gql_expr, {}),
            .gt => try self.addNode(gpa, .gt_expr, {}),
            else => std.debug.panic("Unexpected token {s}", .{self.curr.lexeme(self.src)}),
        }
    }
}

fn parseFactor(self: *Parser, gpa: Allocator) Error!void {
    switch (self.curr.tag) {
        .integer => {
            const n = try std.fmt.parseInt(i64, self.curr.lexeme(self.src), 10);
            const c = try self.interner.intern_i(n);
            try self.addNode(gpa, .const_int, c);
            self.advanceTokens();
        },
        .kw_nil => {
            try self.addNode(gpa, .nil, {});
            self.advanceTokens();
        },
        .identifier => {
            const ident = self.curr.lexeme(self.src);
            const id = try self.interner.intern_s(ident);
            self.advanceTokens();

            if (self.curr.tag == .oparen) {
                // handle the call
                self.advanceTokens(); // eat the paren
                var arg_c: u8 = 0;
                while (self.curr.tag != .cparen) {
                    if (arg_c == std.math.maxInt(u8)) return Error.TooManyArgs;

                    if (arg_c != 0) _ = try self.expectToken(.comma);
                    try self.parseExpr(gpa, 0);
                    arg_c += 1;
                }
                _ = try self.expectToken(.cparen);
                try self.addNode(gpa, .call_expr, .{ .id = id, .arg_c = arg_c });
            } else {
                // if it is not a call it might just be getting the variable
                try self.addNode(gpa, .get_var, id);
            }
        },
        .oparen => {
            self.advanceTokens();
            try self.parseExpr(gpa, 0);
            _ = try self.expectToken(.cparen);
        },
        .bang => {
            self.advanceTokens();
            try self.parseExpr(gpa, 0);
            try self.addNode(gpa, .not_expr, {});
        },
        .minus => {
            self.advanceTokens();
            try self.parseExpr(gpa, 0);
            try self.addNode(gpa, .neg_expr, {});
        },
        else => {
            self.err = "Unexpected token. malformed factor";
            std.debug.print("got {t}\n", .{self.curr.tag});
            return error.UnexpectedToken;
        },
    }
}

fn parseIdentifier(self: *Parser) !u24 {
    const ident_token = try self.expectToken(.identifier);
    const ident = ident_token.lexeme(self.src);
    return try self.interner.intern_s(ident);
}

fn addNode(self: *Parser, gpa: Allocator, comptime tag: Tag, val: @FieldType(Node, @tagName(tag))) !void {
    try self.tags.append(gpa, tag);
    const node = @unionInit(Node, @tagName(tag), val);
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
        .endl, .semi, .eof => {},
        else => {
            std.debug.print("expected .endl, .semi, .eof, got {any}", .{t});
            self.err = "Unfinished statement";
            return error.UnfinishedStmt;
        },
    }
}

fn expectToken(self: *Parser, expected: Token.Tag) Error!Token {
    const t = self.curr;
    self.advanceTokens();
    if (t.tag != expected) {
        return Error.UnexpectedToken;
    }
    return t;
}

fn precedence(tok: Token) u16 {
    // encodes the precedence table
    return switch (tok.tag) {
        .eql_eql, .bang_eql, .lt_eql, .gt_eql, .gt, .lt => 40,
        .plus, .minus => 45,
        .slash, .star, .mod => 50,
        else => std.debug.panic("Unexpected token {t}", .{tok.tag}),
    };
}

// TESTs

const Expected = struct { Tag, Node };

fn expectAst(expected: []const Expected, ast: Ast) !void {
    try std.testing.expectEqual(expected.len, ast.tags.len);
    try std.testing.expectEqual(expected.len, ast.nodes.len);
    for (expected, ast.tags, ast.nodes) |exp, tag, node| {
        try std.testing.expectEqual(exp[0], tag);
        switch (tag) {
            inline else => |t| {
                const name = @tagName(t);
                if (@FieldType(Node, name) == void) continue;
                try std.testing.expectEqual(@field(exp[1], name), @field(node, name));
            },
        }
    }
}

test "size of Node" {
    // The untagged union carries a hidden safety tag in Debug/ReleaseSafe, so
    // it is 8 bytes there, ReleaseFast drops the tag and its 4 bytes.
    const expected: usize = switch (@import("builtin").mode) {
        .Debug, .ReleaseSafe => 8,
        .ReleaseFast, .ReleaseSmall => 4,
    };
    try std.testing.expectEqual(expected, @sizeOf(Node));
}

test "parse: precedence `1 + 2 * 1` parses as 1 + (2 * 1)" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init("1 + 2 * 1", &interner);
    var ast = try parser.parse(gpa);
    defer ast.deinit(gpa);

    const expected = [_]Expected{
        .{ .const_int, .{ .const_int = 0 } },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .mul_expr, undefined },
        .{ .add_expr, undefined },
        .{ .expr_stmt, undefined },
    };
    try expectAst(&expected, ast);
}

test "parse: support both ; and endl as stmt terminators" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var p1 = Parser.init("1 + 2 * 1", &interner);
    var ast1 = try p1.parse(gpa);
    defer ast1.deinit(gpa);

    const expected = [_]Expected{
        .{ .const_int, .{ .const_int = 0 } },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .mul_expr, undefined },
        .{ .add_expr, undefined },
        .{ .expr_stmt, undefined },
    };
    try expectAst(&expected, ast1);

    var p2 = Parser.init("1 + 2 * 1;", &interner);
    var ast2 = try p2.parse(gpa);
    defer ast2.deinit(gpa);
    try expectAst(&expected, ast2);
}

test "parse: using parens to force presedence" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init("(1 + 2) * 1", &interner);
    var ast = try parser.parse(gpa);
    defer ast.deinit(gpa);

    const expected = [_]Expected{
        .{ .const_int, .{ .const_int = 0 } },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .add_expr, undefined },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .mul_expr, undefined },
        .{ .expr_stmt, undefined },
    };
    try expectAst(&expected, ast);
}

test "parse: unary operations correctly" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    var parser = Parser.init("(1 + -2) * 1", &interner);
    var ast = try parser.parse(gpa);
    defer ast.deinit(gpa);

    const expected = [_]Expected{
        .{ .const_int, .{ .const_int = 0 } },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .neg_expr, undefined },
        .{ .add_expr, undefined },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .mul_expr, undefined },
        .{ .expr_stmt, undefined },
    };
    try expectAst(&expected, ast);
}

test "parse: simple block" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ {
        \\      var x = 5
        \\      x = 3; print 1 + 1
        \\      print 2 + x
        \\ }
    ;
    var parser = Parser.init(src, &interner);
    var ast = try parser.parse(gpa);
    defer ast.deinit(gpa);

    const expected = [_]Expected{
        .{ .scope_begin, undefined },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .dec_var, .{ .dec_var = 0 } },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .set_var, .{ .set_var = 0 } },
        .{ .const_int, .{ .const_int = 2 } },
        .{ .const_int, .{ .const_int = 2 } },
        .{ .add_expr, undefined },
        .{ .print_stmt, undefined },
        .{ .const_int, .{ .const_int = 3 } },
        .{ .get_var, .{ .get_var = 0 } },
        .{ .add_expr, undefined },
        .{ .print_stmt, undefined },
        .{ .scope_end, .{ .scope_end = 4 } },
    };
    try expectAst(&expected, ast);
}

test "parse: simple if" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ if x == 0 {
        \\      var x = 5
        \\      print x
        \\ }
    ;
    var parser = Parser.init(src, &interner);
    var ast = try parser.parse(gpa);
    defer ast.deinit(gpa);

    const expected = [_]Expected{
        .{ .get_var, .{ .get_var = 0 } },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .eql_expr, undefined },
        .{ .if_then, undefined },
        .{ .scope_begin, undefined },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .dec_var, .{ .dec_var = 0 } },
        .{ .get_var, .{ .get_var = 0 } },
        .{ .print_stmt, undefined },
        .{ .scope_end, .{ .scope_end = 2 } },
        .{ .if_end, .{ .if_end = 3 } },
    };
    try expectAst(&expected, ast);
}
test "parse: simple if/else" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ if x == 0 {
        \\      var x = 5
        \\      print x
        \\ } else {
        \\    var y = 5
        \\    print y
        \\}
        \\
    ;
    var parser = Parser.init(src, &interner);
    var ast = try parser.parse(gpa);
    defer ast.deinit(gpa);

    const expected = [_]Expected{
        .{ .get_var, .{ .get_var = 0 } },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .eql_expr, undefined },
        .{ .if_then, undefined },
        .{ .scope_begin, undefined },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .dec_var, .{ .dec_var = 0 } },
        .{ .get_var, .{ .get_var = 0 } },
        .{ .print_stmt, undefined },
        .{ .scope_end, .{ .scope_end = 2 } },
        .{ .if_else, undefined },
        .{ .scope_begin, undefined },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .dec_var, .{ .dec_var = 1 } },
        .{ .get_var, .{ .get_var = 1 } },
        .{ .print_stmt, undefined },
        .{ .scope_end, .{ .scope_end = 2 } },
        .{ .if_end, .{ .if_end = 5 } },
    };
    try expectAst(&expected, ast);
}

test "parse: simple if/elseif/else" {
    const gpa = std.testing.allocator;
    var interner = Interner.init(gpa);
    defer interner.deinit();
    const src =
        \\ if x == 0 {
        \\      var x = 5
        \\      print x
        \\ } else if y == 0 {
        \\    var y = 5
        \\    print y
        \\ } else {
        \\    var z = 5
        \\    print z
        \\}
        \\
    ;
    var parser = Parser.init(src, &interner);
    var ast = try parser.parse(gpa);
    defer ast.deinit(gpa);

    const expected = [_]Expected{
        .{ .get_var, .{ .get_var = 0 } },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .eql_expr, undefined },
        .{ .if_then, undefined },
        .{ .scope_begin, undefined },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .dec_var, .{ .dec_var = 0 } },
        .{ .get_var, .{ .get_var = 0 } },
        .{ .print_stmt, undefined },
        .{ .scope_end, .{ .scope_end = 2 } },
        .{ .if_else, undefined },
        .{ .get_var, .{ .get_var = 1 } },
        .{ .const_int, .{ .const_int = 0 } },
        .{ .eql_expr, undefined },
        .{ .if_then, undefined },
        .{ .scope_begin, undefined },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .dec_var, .{ .dec_var = 1 } },
        .{ .get_var, .{ .get_var = 1 } },
        .{ .print_stmt, undefined },
        .{ .scope_end, .{ .scope_end = 2 } },
        .{ .if_else, undefined },
        .{ .scope_begin, undefined },
        .{ .const_int, .{ .const_int = 1 } },
        .{ .dec_var, .{ .dec_var = 2 } },
        .{ .get_var, .{ .get_var = 2 } },
        .{ .print_stmt, undefined },
        .{ .scope_end, .{ .scope_end = 2 } },
        .{ .if_end, .{ .if_end = 5 } },
        .{ .if_end, .{ .if_end = 5 } },
    };
    try expectAst(&expected, ast);
}
