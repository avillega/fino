const std = @import("std");
const Allocator = std.mem.Allocator;
const Lexer = @import("../Lexer.zig");
const Interner = @import("../Interner.zig");

const Token = Lexer.Token;
const Parser = @This();

pub const NodeIdx = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub inline fn from(n: u32) NodeIdx {
        return @enumFromInt(n);
    }

    pub inline fn to(n: NodeIdx) u32 {
        return @intFromEnum(n);
    }
};

pub const ExtraIdx = enum(u32) {
    none = std.math.maxInt(u32),
    _,
    pub inline fn from(n: u32) ExtraIdx {
        return @enumFromInt(n);
    }

    pub inline fn to(n: ExtraIdx) u32 {
        return @intFromEnum(n);
    }
};

const Unary = struct { expr: NodeIdx };
const Binary = struct { lhs: NodeIdx, rhs: NodeIdx };
const Range = struct { start: ExtraIdx, len: u32 };
const Var = struct { id: u24, expr: NodeIdx };

pub const Node = union(enum) {
    root: Range,
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
    call_expr: struct { id: u24, args: Range },
    print_stmt: Unary,
    return_stmt: Unary,
    expr_stmt: Unary,
    scope: Range,
    fndef: struct { id: u24, arity: u8, body: Range },
    if_stmt: struct { cond: NodeIdx, then_branch: NodeIdx, else_branch: NodeIdx },
    while_stmt: struct { cond: NodeIdx, body: NodeIdx },
};

pub const Ast = struct {
    nodes: []Node,
    extra: []NodeIdx,
    pub fn deinit(self: *Ast, gpa: Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.extra);
    }
};

src: [:0]const u8,
curr: Token,
peek: Token,
lexer: Lexer,
err: ?[]const u8,
interner: *Interner,
nodes: std.ArrayList(Node),
extra: std.ArrayList(NodeIdx),
scratch: std.ArrayList(NodeIdx),

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
        .nodes = .empty,
        .extra = .empty,
        .scratch = .empty,
    };

    // prime the curr and peek tokens by calling advance twice
    parser.advanceTokens();
    parser.advanceTokens();
    return parser;
}

pub fn parse(self: *Parser, gpa: Allocator) Error!Ast {
    defer self.scratch.deinit(gpa);
    const marker = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(marker);

    while (true) {
        const dc = try self.parseDecl(gpa);
        if (dc == .none) break;

        try self.scratch.append(gpa, dc);
    }

    const range = try self.addToExtra(gpa, self.scratch.items[marker..]);
    _ = try self.addNode(gpa, .root, range);
    return .{
        .nodes = try self.nodes.toOwnedSlice(gpa),
        .extra = try self.extra.toOwnedSlice(gpa),
    };
}

inline fn advanceTokens(self: *Parser) void {
    self.curr = self.peek;
    self.peek = self.lexer.next();
}

fn parseDecl(self: *Parser, gpa: Allocator) Error!NodeIdx {
    while (self.curr.tag == .endl or self.curr.tag == .semi) {
        self.advanceTokens();
    }
    if (self.curr.tag == .eof) return .none;
    switch (self.curr.tag) {
        .kw_var => {
            self.advanceTokens(); // eat the kw_var
            const global = try self.internIdentifier();
            _ = try self.expectToken(.eql);
            const rvalue = try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            return try self.addNode(gpa, .dec_var, .{ .id = global, .expr = rvalue });
        },
        .kw_fn => {
            self.advanceTokens(); // eat kw_fn
            const name_id = try self.internIdentifier();
            _ = try self.expectToken(.oparen);

            const marker = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(marker);

            var arity: u8 = 0;
            while (self.curr.tag != .cparen) {
                if (self.scratch.items.len - marker == 255) {
                    return Error.TooManyArgs;
                }

                if (self.scratch.items.len - marker != 0) {
                    _ = try self.expectToken(.comma);
                }

                // TODO:  check that this arg_id is not already part of the args_names
                const arg_id = try self.internIdentifier();
                try self.scratch.append(gpa, try self.addNode(gpa, .dec_param, arg_id));
                arity += 1;
            }

            _ = try self.expectToken(.cparen);

            try self.parseBlockItems(gpa);
            const range = try addToExtra(self, gpa, self.scratch.items[marker..]);
            return try self.addNode(gpa, .fndef, .{ .id = name_id, .arity = arity, .body = range });
        },
        else => return try self.parseStmt(gpa),
    }
    unreachable;
}

fn parseStmt(self: *Parser, gpa: Allocator) Error!NodeIdx {
    switch (self.curr.tag) {
        .kw_print => {
            self.advanceTokens(); // eat the kw_print
            const expr = try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            return try self.addNode(gpa, .print_stmt, .{ .expr = expr });
        },
        .identifier => {
            // handle setting to an already declared variable
            if (self.peek.tag == .eql) {
                const ident = self.curr.lexeme(self.src);
                const id = try self.interner.intern_s(ident);

                self.advanceTokens(); // eat the ident
                self.advanceTokens(); // eat the eql

                const expr = try self.parseExpr(gpa, 0);
                try self.expectEndStmt();
                return try self.addNode(gpa, .set_var, .{ .id = id, .expr = expr });
            }

            // otherwise handle it as a normal expression
            const expr = try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            return try self.addNode(gpa, .expr_stmt, .{ .expr = expr });
        },
        .obrace => {
            const range = try self.parseBlock(gpa);
            return try self.addNode(gpa, .scope, range);
        },
        .kw_return => {
            self.advanceTokens(); // eat the kw_return
            var expr: NodeIdx = undefined;
            if (self.curr.tag == .semi or self.curr.tag == .endl) {
                self.advanceTokens(); // eat the separator
                expr = try self.addNode(gpa, .nil, {});
            } else {
                expr = try self.parseExpr(gpa, 0);
                try self.expectEndStmt();
            }
            return try self.addNode(gpa, .return_stmt, .{ .expr = expr });
        },
        .kw_if => {
            return try self.parseIf(gpa);
        },
        .kw_while => {
            self.advanceTokens(); // eat the while
            const cond = try self.parseExpr(gpa, 0); // parse the condition
            const range = try self.parseBlock(gpa);
            const body = try self.addNode(gpa, .scope, range);
            return self.addNode(gpa, .while_stmt, .{ .cond = cond, .body = body });
        },
        else => {
            const expr = try self.parseExpr(gpa, 0);
            try self.expectEndStmt();
            return try self.addNode(gpa, .expr_stmt, .{ .expr = expr });
        },
    }
    unreachable;
}

fn parseIf(self: *Parser, gpa: Allocator) Error!NodeIdx {
    self.advanceTokens(); // eat the if
    const cond = try self.parseExpr(gpa, 0); // parse the condition

    const range = try self.parseBlock(gpa);
    const then_branch = try self.addNode(gpa, .scope, range);

    var else_branch: NodeIdx = .none;

    if (self.curr.tag == .kw_else) {
        self.advanceTokens(); // eat the else
        if (self.curr.tag == .kw_if) {
            else_branch = try self.parseIf(gpa);
        } else {
            const else_range = try self.parseBlock(gpa);
            else_branch = try self.addNode(gpa, .scope, else_range);
        }
    }
    return try self.addNode(gpa, .if_stmt, .{ .cond = cond, .then_branch = then_branch, .else_branch = else_branch });
}

fn parseBlock(self: *Parser, gpa: Allocator) Error!Range {
    const marker = self.scratch.items.len;
    defer self.scratch.shrinkRetainingCapacity(marker);

    try self.parseBlockItems(gpa);

    return try self.addToExtra(gpa, self.scratch.items[marker..]);
}

/// adds to scratch only does not flush into extra or keeps track of markers
fn parseBlockItems(self: *Parser, gpa: Allocator) Error!void {
    _ = try self.expectToken(.obrace); // eat the '{'

    while (true) {
        while (self.curr.tag == .endl or self.curr.tag == .semi) self.advanceTokens();
        if (self.curr.tag == .cbrace or self.curr.tag == .eof) break;
        const nodeidx = try self.parseDecl(gpa);
        if (nodeidx != .none) {
            try self.scratch.append(gpa, nodeidx);
        }
    }

    _ = try self.expectToken(.cbrace); // eat the '}'
}

fn parseExpr(self: *Parser, gpa: Allocator, min_prec: u16) Error!NodeIdx {
    var left = try self.parseFactor(gpa);

    while (isBinOp(self.curr) and precedence(self.curr) >= min_prec) {
        const bin_t = self.curr;
        self.advanceTokens(); // eat the binary operation
        const right = try self.parseExpr(gpa, precedence(bin_t) + 1);
        const bin: Binary = .{ .lhs = left, .rhs = right };
        left = switch (bin_t.tag) {
            .plus => try self.addNode(gpa, .add_expr, bin),
            .minus => try self.addNode(gpa, .sub_expr, bin),
            .slash => try self.addNode(gpa, .div_expr, bin),
            .star => try self.addNode(gpa, .mul_expr, bin),
            .eql_eql => try self.addNode(gpa, .eql_expr, bin),
            .bang_eql => try self.addNode(gpa, .nql_expr, bin),
            .lt => try self.addNode(gpa, .lt_expr, bin),
            .lt_eql => try self.addNode(gpa, .lql_expr, bin),
            .gt_eql => try self.addNode(gpa, .gql_expr, bin),
            .gt => try self.addNode(gpa, .gt_expr, bin),
            else => unreachable,
        };
    }

    return left;
}

fn parseFactor(self: *Parser, gpa: Allocator) Error!NodeIdx {
    switch (self.curr.tag) {
        .integer => {
            const n = try std.fmt.parseInt(i64, self.curr.lexeme(self.src), 10);
            const c = try self.interner.intern_i(n);
            const node = try self.addNode(gpa, .const_int, c);
            self.advanceTokens();
            return node;
        },
        .kw_nil => {
            const node = try self.addNode(gpa, .nil, {});
            self.advanceTokens();
            return node;
        },
        .identifier => {
            const ident = self.curr.lexeme(self.src);
            const id = try self.interner.intern_s(ident);
            self.advanceTokens();

            const marker = self.scratch.items.len;
            defer self.scratch.shrinkRetainingCapacity(marker);

            if (self.curr.tag == .oparen) {
                // handle the call
                self.advanceTokens(); // eat the paren
                while (self.curr.tag != .cparen) {
                    if (self.scratch.items.len - marker == std.math.maxInt(u8)) return Error.TooManyArgs;

                    if (self.scratch.items.len - marker != 0) _ = try self.expectToken(.comma);

                    const node = try self.parseExpr(gpa, 0);
                    try self.scratch.append(gpa, node);
                }
                _ = try self.expectToken(.cparen);
                const range = try self.addToExtra(gpa, self.scratch.items[marker..]);
                return try self.addNode(
                    gpa,
                    .call_expr,
                    .{ .id = id, .args = range },
                );
            } else {
                // if it is not a call its just be getting the variable
                return try self.addNode(gpa, .get_var, id);
            }
        },
        .oparen => {
            self.advanceTokens();
            const expr = try self.parseExpr(gpa, 0);
            _ = try self.expectToken(.cparen);
            return expr;
        },
        .bang => {
            self.advanceTokens();
            const expr = try self.parseExpr(gpa, 0);
            return try self.addNode(gpa, .not_expr, .{ .expr = expr });
        },
        .minus => {
            self.advanceTokens();
            const expr = try self.parseExpr(gpa, 0);
            return try self.addNode(gpa, .neg_expr, .{ .expr = expr });
        },
        else => {
            self.err = "Unexpected token. malformed factor";
            std.debug.print("got {t}\n", .{self.curr.tag});
            return error.UnexpectedToken;
        },
    }
}

inline fn internIdentifier(self: *Parser) !u24 {
    const ident_token = try self.expectToken(.identifier);
    const ident = ident_token.lexeme(self.src);
    return try self.interner.intern_s(ident);
}

inline fn addNode(self: *Parser, gpa: Allocator, comptime tag: std.meta.Tag(Node), v: @FieldType(Node, @tagName(tag))) !NodeIdx {
    const node = @unionInit(Node, @tagName(tag), v);
    const idx: u32 = @intCast(self.nodes.items.len);
    try self.nodes.append(gpa, node);
    return NodeIdx.from(idx);
}

inline fn addToExtra(self: *Parser, gpa: Allocator, items: []NodeIdx) !Range {
    const start = self.extra.items.len;
    try self.extra.appendSlice(gpa, items);
    return .{ .start = ExtraIdx.from(@intCast(start)), .len = @intCast(items.len) };
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

/// check that the current token is of the expected tag
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
    try std.testing.expectEqual(@sizeOf(Node), 16);
}
