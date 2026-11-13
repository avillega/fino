const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("../Lexer.zig");
const Interner = @import("../Interner.zig");

const Token = Lexer.Token;
const Parser = @This();

const Unary = struct { expr: *Node };
const Binary = struct { lhs: *Node, rhs: *Node };
const Block = []*Node;
const Var = struct { id: u24, expr: *Node };

pub const Node = union(enum) {
    root: Block,
    nil,
    const_int: u24,
    get_var: u24,
    dec_param: u24,
    dec_var: Var,
    set_var: Var,
    neg_expr: Unary,
    not_expr: Unary,
    add_expr: Binary,
    sub_expr: Binary,
    mul_expr: Binary,
    div_expr: Binary,
    eql_expr: Binary,
    nql_expr: Binary,
    lt_expr: Binary,
    lql_expr: Binary,
    gt_expr: Binary,
    gql_expr: Binary,
    call_expr: struct { id: u24, args: []*Node },
    print_stmt: Unary,
    return_stmt: Unary,
    expr_stmt: Unary,
    scope: Block,
    fndef: struct { id: u24, arity: u8, body: Block },
    if_stmt: struct { cond: *Node, then_branch: *Node, else_branch: ?*Node },
    while_stmt: struct { cond: *Node, body: *Node },
};

pub const Ast = *Node;

src: [:0]const u8,
curr: Token,
peek: Token,
lexer: Lexer,
err: ?[]const u8,
interner: *Interner,

const Error = error{
    UnexpectedToken,
    UnfinishedStmt,
    TooManyArgs,
} || Allocator.Error || std.fmt.ParseIntError;

pub fn init(src: [:0]const u8, interner: *Interner) Parser {
    var parser: Parser = .{
        .src = src,
        .lexer = Lexer.init(src),
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

pub fn parse(self: *Parser, arena: Allocator) Error!Ast {
    var decls: std.ArrayList(*Node) = .empty;
    while (try self.parseDecl(arena)) |decl| {
        try decls.append(arena, decl);
    }
    return createNode(arena, .root, try decls.toOwnedSlice(arena));
}

fn advanceTokens(self: *Parser) void {
    self.curr = self.peek;
    self.peek = self.lexer.next();
}

fn parseDecl(self: *Parser, arena: Allocator) Error!?*Node {
    while (self.curr.tag == .endl or self.curr.tag == .semi) {
        self.advanceTokens();
    }
    if (self.curr.tag == .eof) return null;
    switch (self.curr.tag) {
        .kw_var => {
            self.advanceTokens(); // eat the kw_var
            const global = try self.internIdentifier();
            _ = try self.expectToken(.eql);
            const rvalue = try self.parseExpr(arena, 0);
            try self.expectEndStmt();
            return try createNode(arena, .dec_var, .{ .id = global, .expr = rvalue });
        },
        .kw_fn => {
            self.advanceTokens(); // eat kw_fn
            const name_id = try self.internIdentifier();
            _ = try self.expectToken(.oparen);

            var arity: u8 = 0;
            var body: std.ArrayList(*Node) = try .initCapacity(arena, 255);
            while (self.curr.tag != .cparen) {
                if (body.items.len == 255) {
                    return Error.TooManyArgs;
                }

                if (body.items.len != 0) {
                    _ = try self.expectToken(.comma);
                }

                // TODO:  check that this arg_id is not already part of the args_names
                const arg_id = try self.internIdentifier();
                body.appendAssumeCapacity(try createNode(arena, .dec_param, arg_id));
                arity += 1;
            }

            _ = try self.expectToken(.cparen);

            try self.parseBlock(arena, &body);
            return try createNode(arena, .fndef, .{ .id = name_id, .arity = arity, .body = try body.toOwnedSlice(arena) });
        },
        else => return self.parseStmt(arena),
    }
    unreachable;
}

fn parseStmt(self: *Parser, arena: Allocator) Error!*Node {
    switch (self.curr.tag) {
        .kw_print => {
            self.advanceTokens(); // eat the kw_print
            const expr = try self.parseExpr(arena, 0);
            try self.expectEndStmt();
            return try createNode(arena, .print_stmt, .{ .expr = expr });
        },
        .identifier => {
            // handle setting to an already declared variable
            if (self.peek.tag == .eql) {
                const ident = self.curr.lexeme(self.src);
                const id = try self.interner.intern_s(ident);

                self.advanceTokens(); // eat the ident
                self.advanceTokens(); // eat the eql

                const expr = try self.parseExpr(arena, 0);
                try self.expectEndStmt();
                return try createNode(arena, .set_var, .{ .id = id, .expr = expr });
            }

            // otherwise handle it as a normal expression
            const expr = try self.parseExpr(arena, 0);
            try self.expectEndStmt();
            return try createNode(arena, .expr_stmt, .{ .expr = expr });
        },
        .obrace => {
            var block: std.ArrayList(*Node) = .empty;
            try self.parseBlock(arena, &block);
            return try createNode(arena, .scope, try block.toOwnedSlice(arena));
        },
        .kw_return => {
            self.advanceTokens(); // eat the kw_return
            var expr: *Node = undefined;
            if (self.curr.tag == .semi or self.curr.tag == .endl) {
                self.advanceTokens(); // eat the separator
                expr = try createNode(arena, .nil, {});
            } else {
                expr = try self.parseExpr(arena, 0);
                try self.expectEndStmt();
            }
            return try createNode(arena, .return_stmt, .{ .expr = expr });
        },
        .kw_if => {
            return try self.parseIf(arena);
        },
        .kw_while => {
            self.advanceTokens(); // eat the while
            const cond = try self.parseExpr(arena, 0); // parse the condition

            var body_l: std.ArrayList(*Node) = .empty;
            try self.parseBlock(arena, &body_l);
            const body = try createNode(arena, .scope, try body_l.toOwnedSlice(arena));
            return createNode(arena, .while_stmt, .{ .cond = cond, .body = body });
        },
        else => {
            const expr = try self.parseExpr(arena, 0);
            try self.expectEndStmt();
            return try createNode(arena, .expr_stmt, .{ .expr = expr });
        },
    }
    unreachable;
}

fn parseIf(self: *Parser, arena: Allocator) Error!*Node {
    self.advanceTokens(); // eat the if
    const cond = try self.parseExpr(arena, 0); // parse the condition

    var then_block: std.ArrayList(*Node) = .empty;
    try self.parseBlock(arena, &then_block);
    const then_branch = try createNode(arena, .scope, try then_block.toOwnedSlice(arena));

    var else_branch: ?*Node = null;

    if (self.curr.tag == .kw_else) {
        self.advanceTokens(); // eat the else
        if (self.curr.tag == .kw_if) {
            else_branch = try self.parseIf(arena);
        } else {
            var else_block: std.ArrayList(*Node) = .empty;
            try self.parseBlock(arena, &else_block);
            else_branch = try createNode(arena, .scope, try else_block.toOwnedSlice(arena));
        }
    }
    return try createNode(arena, .if_stmt, .{ .cond = cond, .then_branch = then_branch, .else_branch = else_branch });
}

fn parseBlock(self: *Parser, arena: Allocator, block: *std.ArrayList(*Node)) Error!void {
    _ = try self.expectToken(.obrace); // eat the '{'

    while (true) {
        while (self.curr.tag == .endl or self.curr.tag == .semi) self.advanceTokens();
        if (self.curr.tag == .cbrace or self.curr.tag == .eof) break;
        if (try self.parseDecl(arena)) |node| {
            try block.append(arena, node);
        }
    }

    _ = try self.expectToken(.cbrace); // eat the '}'
}

fn parseExpr(self: *Parser, arena: Allocator, min_prec: u16) Error!*Node {
    var left = try self.parseFactor(arena);

    while (isBinOp(self.curr) and precedence(self.curr) >= min_prec) {
        const bin_t = self.curr;
        self.advanceTokens(); // eat the binary operation
        const right = try self.parseExpr(arena, precedence(bin_t) + 1);
        const bin: Binary = .{ .lhs = left, .rhs = right };
        left = try arena.create(Node);
        left.* = switch (bin_t.tag) {
            .plus => .{ .add_expr = bin },
            .minus => .{ .sub_expr = bin },
            .slash => .{ .div_expr = bin },
            .star => .{ .mul_expr = bin },
            .eql_eql => .{ .eql_expr = bin },
            .bang_eql => .{ .nql_expr = bin },
            .lt => .{ .lt_expr = bin },
            .lt_eql => .{ .lql_expr = bin },
            .gt_eql => .{ .gql_expr = bin },
            .gt => .{ .gt_expr = bin },
            else => unreachable,
        };
    }

    return left;
}

fn parseFactor(self: *Parser, arena: Allocator) Error!*Node {
    switch (self.curr.tag) {
        .integer => {
            const n = try std.fmt.parseInt(i64, self.curr.lexeme(self.src), 10);
            const c = try self.interner.intern_i(n);
            const node = try createNode(arena, .const_int, c);
            self.advanceTokens();
            return node;
        },
        .kw_nil => {
            const node = try createNode(arena, .nil, {});
            self.advanceTokens();
            return node;
        },
        .identifier => {
            const ident = self.curr.lexeme(self.src);
            const id = try self.interner.intern_s(ident);
            self.advanceTokens();
            var args: std.ArrayList(*Node) = .empty;

            if (self.curr.tag == .oparen) {
                // handle the call
                self.advanceTokens(); // eat the paren
                while (self.curr.tag != .cparen) {
                    if (args.items.len == std.math.maxInt(u8)) return Error.TooManyArgs;

                    if (args.items.len != 0) _ = try self.expectToken(.comma);

                    const node = try self.parseExpr(arena, 0);
                    try args.append(arena, node);
                }
                _ = try self.expectToken(.cparen);
                return try createNode(
                    arena,
                    .call_expr,
                    .{ .id = id, .args = try args.toOwnedSlice(arena) },
                );
            } else {
                // if it is not a call its just be getting the variable
                return try createNode(arena, .get_var, id);
            }
        },
        .oparen => {
            self.advanceTokens();
            const expr = try self.parseExpr(arena, 0);
            _ = try self.expectToken(.cparen);
            return expr;
        },
        .bang => {
            self.advanceTokens();
            const expr = try self.parseExpr(arena, 0);
            return try createNode(arena, .not_expr, .{ .expr = expr });
        },
        .minus => {
            self.advanceTokens();
            const expr = try self.parseExpr(arena, 0);
            return try createNode(arena, .neg_expr, .{ .expr = expr });
        },
        else => {
            self.err = "Unexpected token. malformed factor";
            std.debug.print("got {t}\n", .{self.curr.tag});
            return error.UnexpectedToken;
        },
    }
}

fn internIdentifier(self: *Parser) !u24 {
    const ident_token = try self.expectToken(.identifier);
    const ident = ident_token.lexeme(self.src);
    return try self.interner.intern_s(ident);
}

fn createNode(arena: Allocator, comptime tag: std.meta.Tag(Node), v: @FieldType(Node, @tagName(tag))) !*Node {
    const node = try arena.create(Node);
    node.* = @unionInit(Node, @tagName(tag), v);
    return node;
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

test "size of Node" {
    try std.testing.expectEqual(@sizeOf(Node), 32);
}
