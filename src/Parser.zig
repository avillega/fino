src: []const u8,
token: struct {
    tag: []Token.Tag,
    offset: []u24,
    count: u32,
    idx: u32,

    pub fn curr(self: @This()) Token {
        if (self.idx == self.count) return .{
            .tag = self.tag[self.count - 1],
            .offset = self.offset[self.count - 1],
        };

        return .{
            .tag = self.tag[self.idx],
            .offset = self.offset[self.idx],
        };
    }

    // return the token after current
    pub fn peek(self: @This()) Token {
        if (self.idx + 1 < self.count) return .{
            .tag = self.tag[self.idx + 1],
            .offset = self.offset[self.idx + 1],
        };

        return .{
            .tag = self.tag[self.count - 1],
            .offset = self.offset[self.count - 1],
        };
    }
},

node: struct {
    tag: []Node.Tag,
    repr: []u32,
    count: u32,
},

interner: std.StringHashMapUnmanaged(u24),

const Parser = @This();

const Error = error{
    oom,
    nyi,
    too_many_args,
    unfinished_stmt,
    unexpected_token,
    too_many_captures,
    invalid_assignment_target,
    nested_idexing_not_supported,
};

pub const empty: Parser = .{
    .src = &.{},
    .token = .{
        .tag = &.{},
        .offset = &.{},
        .count = 0,
        .idx = 0,
    },
    .node = .{
        .tag = &.{},
        .repr = &.{},
        .count = 0,
    },
    .interner = .empty,
};

pub fn reserve(p: *Parser, gpa: Allocator, capacity: struct {
    tokens: u32,
    nodes: u32,
    strings: u32,
}) !void {
    try reserve_slice(gpa, &p.token.tag, capacity.tokens);
    try reserve_slice(gpa, &p.token.offset, capacity.tokens);

    try reserve_slice(gpa, &p.node.tag, capacity.nodes);
    try reserve_slice(gpa, &p.node.repr, capacity.nodes);

    p.interner.clearRetainingCapacity();
    try p.interner.ensureTotalCapacity(gpa, capacity.strings);
}

pub fn deinit(p: *Parser, gpa: Allocator) void {
    p.interner.clearAndFree(gpa);
    gpa.free(p.token.tag);
    gpa.free(p.token.offset);
}

pub fn parse(p: *Parser, src: []const u8) !void {
    if (src.len > std.math.maxInt(u32)) return error.OOM;

    assert(p.src.len == 0);
    p.src = src;
    p.interner.clearRetainingCapacity();
    defer p.interner.clearRetainingCapacity();

    try p.tokenize();
    try p.do_parse();
    // assert(!p.oomed);
}

pub fn ast(p: *Parser) Ast {
    return .{
        .src = p.src,
        .node = .{
            .tag = p.node.tag[0..p.node.count],
            .repr = p.node.repr[0..p.node.count],
        },
    };
}

fn reserve_slice(gpa: Allocator, slice_ptr: anytype, capacity: u32) !void {
    assert(@typeInfo(@TypeOf(slice_ptr)).pointer.size == .one);
    const Slice = @typeInfo(@TypeOf(slice_ptr)).pointer.child;
    assert(@typeInfo(Slice).pointer.size == .slice);
    const T = @typeInfo(Slice).pointer.child;

    if (slice_ptr.len >= capacity) return;
    const slice_new = try gpa.alloc(T, capacity);
    gpa.free(slice_ptr.*);
    slice_ptr.* = slice_new;
}

fn tokenize(p: *Parser) Error!void {
    var t: Tokenizer = .init(p.src);
    while (true) {
        const token = t.next();
        if (p.token.count == p.token.tag.len) return error.oom;
        p.token.tag[p.token.count] = token.tag;
        p.token.offset[p.token.count] = token.offset;
        p.token.count += 1;
        if (token.tag == .eof) break;
    }
}

fn do_parse(p: *Parser) !void {
    while (true) {
        switch (p.token.curr().tag) {
            .eof => return,
            .sep => {
                p.token.idx += 1;
                continue;
            },
            .@"fn" => { // fn can only be instantiated at the top level of the file
                p.token.idx += 1;
                const fn_name = p.token.curr();
                try p.expect(.name);
                try p.expect(.@"(");

                var params: [std.math.maxInt(u8)]u24 = undefined;
                var count: u8 = 0;
                while (p.token.curr().tag != .@")") {
                    if (count == std.math.maxInt(u8)) return error.too_many_args;
                    if (count > 0) try p.expect(.@",");
                    const p_name = p.token.curr();
                    try p.expect(.name);
                    params[count] = p_name.offset;
                    count += 1;
                }
                try p.expect(.@")");
                try p.add_node(.fn_begin, @backingInt(Node.Fn{
                    .name_id = p.intern(fn_name.offset),
                    .argc = count,
                }));

                for (params[0..count]) |offset| {
                    try p.add_node(.dec_param, p.intern(offset));
                }
                try p.parse_block();
                try p.add_node(.fn_end, 0);
            },
            else => try p.parse_stmt(),
        }
    }
}

fn parse_stmt(p: *Parser) Error!void {
    while (p.token.curr().tag == .sep) p.token.idx += 1;
    if (p.token.curr().tag == .eof) return;

    switch (p.token.curr().tag) {
        .name => switch (p.token.peek().tag) {
            inline .@"=", .@":=" => |tag| {
                const id = p.token.curr().offset;
                p.token.idx += 1; // eats the name
                p.token.idx += 1; // eats the = or :=
                try p.parse_expr(0);
                try p.end_stmt();
                try p.add_node(
                    if (tag == .@"=") .set_var else .dec_var,
                    p.intern(id),
                );
            },
            else => {
                const s = p.node.count;
                try p.parse_expr(0);
                switch (p.token.curr().tag) {
                    .@"=" => {
                        if (p.node.tag[s] != .get_var or p.node.tag[p.node.count - 1] != .get_idx) {
                            return error.invalid_assignment_target;
                        }

                        p.node.count -= 1;
                        p.token.idx += 1;
                        try p.parse_expr(0);
                        try p.add_node(.set_idx, 0);
                    },
                    else => {
                        try p.add_node(.discard, 0);
                        try p.end_stmt();
                    },
                }
            },
        },
        .@"return" => {
            p.token.idx += 1;
            const t = p.token.curr().tag;
            switch (t) {
                .sep, .@"}" => try p.add_node(.nil, 0),
                else => try p.parse_expr(0),
            }
            try p.end_stmt();
            try p.add_node(.ret, 0);
        },
        .@"while" => {
            p.token.idx += 1;
            try p.add_node(.while_begin, 0);
            try p.parse_expr(0); // cond
            try p.add_node(.while_do, 0);
            try p.parse_block();
            try p.add_node(.while_end, 0);
        },
        .@"if" => try p.parse_if(),
        .@"for" => try p.parse_for(),
        .@"{" => try p.parse_block(),
        else => {
            try p.parse_expr(0);
            try p.add_node(.discard, 0);
            try p.end_stmt();
        },
    }
}

fn parse_expr(p: *Parser, min_prec: u16) Error!void {
    // left
    try p.parse_factor();

    while (bin_op(p.token.curr().tag)) |op| {
        if (op.prec < min_prec) break;
        p.token.idx += 1;
        if (op.infix) |marker| try p.add_node(marker, 0);
        // right
        try p.parse_expr(op.prec + 1);
        for (op.tags) |tag| {
            try p.add_node(tag, 0);
        }
    }
}

fn bin_op(tag: Token.Tag) ?struct { tags: []const Node.Tag, prec: u16, infix: ?Node.Tag = null } {
    return switch (tag) {
        .@"or" => .{ .tags = &.{.or_end}, .prec = 30, .infix = .or_then },
        .@"and" => .{ .tags = &.{.and_end}, .prec = 35, .infix = .and_then },
        .@"==" => .{ .tags = &.{.eql}, .prec = 40 },
        .@"!=" => .{ .tags = &.{ .eql, .not }, .prec = 40 },
        .@"<" => .{ .tags = &.{.lt}, .prec = 40 },
        .@"<=" => .{ .tags = &.{ .gt, .not }, .prec = 40 },
        .@">" => .{ .tags = &.{.gt}, .prec = 40 },
        .@">=" => .{ .tags = &.{ .lt, .not }, .prec = 40 },
        .@"+" => .{ .tags = &.{.add}, .prec = 45 },
        .@"-" => .{ .tags = &.{.sub}, .prec = 45 },
        .@"*" => .{ .tags = &.{.mul}, .prec = 50 },
        .@"/" => .{ .tags = &.{.div}, .prec = 50 },
        .@"%" => .{ .tags = &.{.mod}, .prec = 50 },
        else => null,
    };
}

fn parse_factor(p: *Parser) Error!void {
    switch (p.token.curr().tag) {
        .nil => {
            try p.add_node(.nil, 0);
            p.token.idx += 1;
        },
        .number => {
            try p.add_node(.num, p.token.curr().offset);
            p.token.idx += 1;
        },
        .string => {
            try p.add_node(.str, p.intern(p.token.curr().offset));
            p.token.idx += 1;
        },
        .atom => {
            try p.add_node(.atom, p.intern(p.token.curr().offset));
            p.token.idx += 1;
        },
        .@"[" => {
            p.token.idx += 1;
            var elem_count: u32 = 0;
            while (p.token.curr().tag == .sep) p.token.idx += 1;
            while (true) {
                if (p.token.curr().tag == .@"]" or p.token.curr().tag == .eof) break;
                if (elem_count > 0) try p.expect(.@",");
                try p.parse_expr(0);
                elem_count += 1;
            }
            try p.expect(.@"]");
            try p.add_node(.arr, elem_count);
        },
        .@".{" => {
            p.token.idx += 1;
            var pair_count: u32 = 0;
            while (p.token.curr().tag == .sep) p.token.idx += 1;
            while (true) {
                if (p.token.curr().tag == .@"}" or p.token.curr().tag == .eof) break;
                if (pair_count > 0) try p.expect(.@",");
                const atom = p.token.curr();
                try p.expect(.atom);
                try p.add_node(.atom, p.intern(atom.offset));
                try p.parse_expr(0);
                pair_count += 1;
            }
            try p.expect(.@"}");
            try p.add_node(.record, pair_count);
        },
        .true => {},
        .false => {},
        .@"(" => {
            p.token.idx += 1;
            try p.parse_expr(0);
            try p.expect(.@")");
        },
        .@"!" => {
            p.token.idx += 1;
            try p.parse_factor();
            try p.add_node(.not, 0);
        },
        .@"-" => {
            p.token.idx += 1;
            try p.parse_factor();
            try p.add_node(.neg, 0);
        },
        .name => {
            const id = p.token.curr().offset;
            p.token.idx += 1;
            switch (p.token.curr().tag) {
                .@"(" => {
                    p.token.idx += 1;
                    var argc: u8 = 0;
                    while (p.token.curr().tag != .@")") {
                        if (argc == std.math.maxInt(u8)) return error.too_many_args;
                        if (argc != 0) try p.expect(.@",");
                        try p.parse_expr(0);
                        argc += 1;
                    }
                    try p.expect(.@")");
                    try p.add_node(.call, @backingInt(Node.Fn{ .name_id = p.intern(id), .argc = argc }));
                },
                else => try p.add_node(.get_var, p.intern(id)),
            }
        },
        else => {
            return error.unexpected_token;
        },
    }

    // post-fix loop only handles [] (indexing for know)
    var idx_depth: u8 = 0;
    while (p.token.curr().tag == .@"[") {
        if (idx_depth > 0) return error.nested_idexing_not_supported;
        idx_depth += 1;
        p.token.idx += 1;
        try p.parse_expr(0);
        try p.expect(.@"]");
        try p.add_node(.get_idx, 0);
    }
}

fn parse_if(p: *Parser) Error!void {
    p.token.idx += 1; // eat the if
    try p.parse_expr(0); // parse the condition
    try p.add_node(.if_then, 0);
    try p.parse_block();
    if (p.token.curr().tag == .@"else") {
        p.token.idx += 1;
        try p.add_node(.if_else, 0);
        if (p.token.curr().tag == .@"if") {
            try p.parse_if();
        } else {
            try p.parse_block();
        }
        try p.add_node(.if_end_else, 0);
    } else {
        try p.add_node(.if_end, 0);
    }
}

fn parse_for(p: *Parser) !void {
    try p.expect(.@"for"); // eat the 'for'
    try p.expect(.@"(");
    while (p.token.curr().tag == .sep) p.token.idx += 1;
    try p.parse_expr(0);
    while (p.token.curr().tag == .sep) p.token.idx += 1;
    try p.expect(.@")");
    try p.add_node(.for_do, 0);

    try p.expect(.@"|");
    var capts: u8 = 0;
    while (capts < 2) { // only allow 1 or 2 captures
        switch (p.token.curr().tag) {
            .sep => p.token.idx += 1,
            .@"|", .eof => break,
            else => {
                if (capts > 0) try p.expect(.@",");
                const name = p.token.curr();
                try p.expect(.name);
                try p.add_node(.dec_capture, p.intern(name.offset));
                capts += 1;
            },
        }
    }
    p.expect(.@"|") catch return error.too_many_captures;
    assert(capts <= 2);
    while (p.token.curr().tag == .sep) p.token.idx += 1;
    try p.parse_block();
    try p.add_node(.for_end, capts);
}

fn parse_block(p: *Parser) Error!void {
    try p.expect(.@"{");
    try p.add_node(.scope_begin, 0);
    while (true) {
        switch (p.token.curr().tag) {
            .sep => {
                p.token.idx += 1;
                continue;
            },
            .eof, .@"}" => break,
            else => try p.parse_stmt(),
        }
    }
    try p.expect(.@"}");
    try p.add_node(.scope_end, 0);
}

fn add_node(p: *Parser, tag: Node.Tag, repr: u32) !void {
    if (p.node.count == p.node.tag.len) return error.oom;
    p.node.tag[p.node.count] = tag;
    p.node.repr[p.node.count] = repr;
    p.node.count += 1;
}

fn expect(p: *Parser, expected: Token.Tag) !void {
    if (p.token.curr().tag != expected) return error.unexpected_token;
    p.token.idx += 1;
}

fn end_stmt(p: *Parser) !void {
    const t = p.token.curr().tag;
    switch (t) {
        .sep, .eof => p.token.idx += 1,
        .@"}" => {},
        else => return error.unfinished_stmt,
    }
}

fn intern(p: *Parser, offset: u24) u24 {
    var t: Tokenizer = .{
        .src = p.src,
        .offset = offset,
    };
    _ = t.next();
    const lexeme = p.src[offset..t.offset];
    const res = p.interner.getOrPutAssumeCapacity(lexeme);
    if (!res.found_existing) {
        res.value_ptr.* = offset;
    }
    return res.value_ptr.*;
}

// Tests

fn check(src: []const u8, expected: []const Node) !void {
    var p: Parser = .empty;
    try p.reserve(std.testing.allocator, .{ .nodes = 256, .tokens = 256, .strings = 256 });

    defer p.deinit(std.testing.allocator);
    defer std.testing.allocator.free(p.node.tag);
    defer std.testing.allocator.free(p.node.repr);

    try p.parse(src);
    const parsed = p.ast();
    const actual = try parsed.node_slice(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(Node, expected, actual);
}

test "size of Node representation" {
    try std.testing.expectEqual(1, @sizeOf(Node.Tag));
    try std.testing.expectEqual(4, @sizeOf(@FieldType(Node, "repr")));
}

test "parse: precedence 1 + 2 * 1" {
    try check("1 + 2 * 1", &.{
        .{ .tag = .num, .repr = 0 },
        .{ .tag = .num, .repr = 4 },
        .{ .tag = .num, .repr = 8 },
        .{ .tag = .mul },
        .{ .tag = .add },
        .{ .tag = .discard },
    });
}

test "parse: support both ; and endl as stmt terminators" {
    const expected = [_]Node{
        .{ .tag = .num, .repr = 0 },
        .{ .tag = .num, .repr = 4 },
        .{ .tag = .num, .repr = 8 },
        .{ .tag = .mul },
        .{ .tag = .add },
        .{ .tag = .discard },
    };
    try check("1 + 2 * 1", &expected);
    try check("1 + 2 * 1;", &expected);
    try check("1 + 2 * 1\n", &expected);
}

test "parse: using parens to force precedence" {
    try check("(1 + 2) * 1", &.{
        .{ .tag = .num, .repr = 1 },
        .{ .tag = .num, .repr = 5 },
        .{ .tag = .add },
        .{ .tag = .num, .repr = 10 },
        .{ .tag = .mul },
        .{ .tag = .discard },
    });
}

test "parse: unary operations correctly" {
    try check("(1 + -2) * 1", &.{
        .{ .tag = .num, .repr = 1 },
        .{ .tag = .num, .repr = 6 },
        .{ .tag = .neg },
        .{ .tag = .add },
        .{ .tag = .num, .repr = 11 },
        .{ .tag = .mul },
        .{ .tag = .discard },
    });
}

test "parse: simple block" {
    try check("{ x := 5; x = 3; print(1 + 1); print(2 + x) }", &.{
        .{ .tag = .scope_begin },
        .{ .tag = .num, .repr = 7 },
        .{ .tag = .dec_var, .repr = 2 },
        .{ .tag = .num, .repr = 14 },
        .{ .tag = .set_var, .repr = 2 },
        .{ .tag = .num, .repr = 23 },
        .{ .tag = .num, .repr = 27 },
        .{ .tag = .add },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 17, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .num, .repr = 37 },
        .{ .tag = .get_var, .repr = 2 },
        .{ .tag = .add },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 17, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
    });
}

test "parse: simple while" {
    const s =
        \\ i := 0
        \\ while i < 10 { i = i + 1 }
    ;
    try check(s, &.{
        .{ .tag = .num, .repr = 6 },
        .{ .tag = .dec_var, .repr = 1 },
        .{ .tag = .while_begin },
        .{ .tag = .get_var, .repr = 1 },
        .{ .tag = .num, .repr = 19 },
        .{ .tag = .lt },
        .{ .tag = .while_do },
        .{ .tag = .scope_begin },
        .{ .tag = .get_var, .repr = 1 },
        .{ .tag = .num, .repr = 32 },
        .{ .tag = .add },
        .{ .tag = .set_var, .repr = 1 },
        .{ .tag = .scope_end },
        .{ .tag = .while_end },
    });
}

test "parse: function definition payload" {
    try check("fn sum(a, b) { return a }", &.{
        .{ .tag = .fn_begin, .repr = 0x02000003 },
        .{ .tag = .dec_param, .repr = 7 },
        .{ .tag = .dec_param, .repr = 10 },
        .{ .tag = .scope_begin },
        .{ .tag = .get_var, .repr = 7 },
        .{ .tag = .ret },
        .{ .tag = .scope_end },
        .{ .tag = .fn_end },
    });
}

test "parse: simple function call" {
    try check("print(x); print(1+2)", &.{
        .{ .tag = .get_var, .repr = 6 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 0, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .num, .repr = 16 },
        .{ .tag = .num, .repr = 18 },
        .{ .tag = .add },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 0, .argc = 1 }) },
        .{ .tag = .discard },
    });
}

test "parse: simple if" {
    try check("if x == 0 { x := 5; print(x) }", &.{
        .{ .tag = .get_var, .repr = 3 },
        .{ .tag = .num, .repr = 8 },
        .{ .tag = .eql },
        .{ .tag = .if_then },
        .{ .tag = .scope_begin },
        .{ .tag = .num, .repr = 17 },
        .{ .tag = .dec_var, .repr = 3 },
        .{ .tag = .get_var, .repr = 3 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 20, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
        .{ .tag = .if_end },
    });
}

test "parse: simple if/else" {
    try check("if x == 0 { x := 5; print(x) } else { y := 5; print(y) }", &.{
        .{ .tag = .get_var, .repr = 3 },
        .{ .tag = .num, .repr = 8 },
        .{ .tag = .eql },
        .{ .tag = .if_then },
        .{ .tag = .scope_begin },
        .{ .tag = .num, .repr = 17 },
        .{ .tag = .dec_var, .repr = 3 },
        .{ .tag = .get_var, .repr = 3 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 20, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
        .{ .tag = .if_else },
        .{ .tag = .scope_begin },
        .{ .tag = .num, .repr = 43 },
        .{ .tag = .dec_var, .repr = 38 },
        .{ .tag = .get_var, .repr = 38 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 20, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
        .{ .tag = .if_end_else },
    });
}

test "parse: simple if/elseif/else" {
    try check("if x == 0 { x := 5; print(x) } else if y == 0 { y := 5; print(y) } else { z := 5; print(z) }", &.{
        .{ .tag = .get_var, .repr = 3 },
        .{ .tag = .num, .repr = 8 },
        .{ .tag = .eql },
        .{ .tag = .if_then },
        .{ .tag = .scope_begin },
        .{ .tag = .num, .repr = 17 },
        .{ .tag = .dec_var, .repr = 3 },
        .{ .tag = .get_var, .repr = 3 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 20, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
        .{ .tag = .if_else },
        .{ .tag = .get_var, .repr = 39 },
        .{ .tag = .num, .repr = 44 },
        .{ .tag = .eql },
        .{ .tag = .if_then },
        .{ .tag = .scope_begin },
        .{ .tag = .num, .repr = 53 },
        .{ .tag = .dec_var, .repr = 39 },
        .{ .tag = .get_var, .repr = 39 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 20, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
        .{ .tag = .if_else },
        .{ .tag = .scope_begin },
        .{ .tag = .num, .repr = 79 },
        .{ .tag = .dec_var, .repr = 74 },
        .{ .tag = .get_var, .repr = 74 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 20, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
        .{ .tag = .if_end_else },
        .{ .tag = .if_end_else },
    });
}

test "parse: simple string literal" {
    try check("a := \"my_string/lit\"", &.{
        .{ .tag = .str, .repr = 5 },
        .{ .tag = .dec_var, .repr = 0 },
    });
}

test "parse: simple array literal" {
    try check("a := [x, y, z, w]", &.{
        .{ .tag = .get_var, .repr = 6 },
        .{ .tag = .get_var, .repr = 9 },
        .{ .tag = .get_var, .repr = 12 },
        .{ .tag = .get_var, .repr = 15 },
        .{ .tag = .arr, .repr = 4 },
        .{ .tag = .dec_var, .repr = 0 },
    });
}

test "parse: simple array index get" {
    try check("a[10]", &.{
        .{ .tag = .get_var, .repr = 0 },
        .{ .tag = .num, .repr = 2 },
        .{ .tag = .get_idx },
        .{ .tag = .discard },
    });
}

test "parse: simple array index set" {
    try check("a[10] = 2", &.{
        .{ .tag = .get_var },
        .{ .tag = .num, .repr = 2 },
        .{ .tag = .num, .repr = 8 },
        .{ .tag = .set_idx },
    });
}

test "parse: simple array index set with expression as index" {
    try check("a[10+2] = 2", &.{
        .{ .tag = .get_var },
        .{ .tag = .num, .repr = 2 },
        .{ .tag = .num, .repr = 5 },
        .{ .tag = .add },
        .{ .tag = .num, .repr = 10 },
        .{ .tag = .set_idx },
    });
}

test "parse: array index error" {
    var p: Parser = .empty;
    try p.reserve(std.testing.allocator, .{ .nodes = 256, .tokens = 256, .strings = 256 });
    defer p.deinit(std.testing.allocator);
    defer std.testing.allocator.free(p.node.tag);
    defer std.testing.allocator.free(p.node.repr);

    try std.testing.expectError(error.invalid_assignment_target, p.parse("a[10] + 10 = 2"));
}

test "parse: record" {
    try check(".{ :a \"hello\", :world \"another\"}", &.{
        .{ .tag = .atom, .repr = 3 },
        .{ .tag = .str, .repr = 6 },
        .{ .tag = .atom, .repr = 15 },
        .{ .tag = .str, .repr = 22 },
        .{ .tag = .record, .repr = 2 },
        .{ .tag = .discard },
    });
}

test "parse: for" {
    try check("for (record) |k, v| { print(k) }", &.{
        .{ .tag = .get_var, .repr = 5 },
        .{ .tag = .for_do },
        .{ .tag = .dec_capture, .repr = 14 },
        .{ .tag = .dec_capture, .repr = 17 },
        .{ .tag = .scope_begin },
        .{ .tag = .get_var, .repr = 14 },
        .{ .tag = .call, .repr = @backingInt(Node.Fn{ .name_id = 22, .argc = 1 }) },
        .{ .tag = .discard },
        .{ .tag = .scope_end },
        .{ .tag = .for_end, .repr = 2 },
    });
}

test "parse: simple record index get" {
    try check("a[:a]", &.{
        .{ .tag = .get_var, .repr = 0 },
        .{ .tag = .atom, .repr = 2 },
        .{ .tag = .get_idx },
        .{ .tag = .discard },
    });
}

test "parse: simple and" {
    try check("a = a and b", &.{
        .{ .tag = .get_var, .repr = 4 },
        .{ .tag = .and_then },
        .{ .tag = .get_var, .repr = 10 },
        .{ .tag = .and_end },
        .{ .tag = .set_var, .repr = 4 },
    });
}

test "parse: simple or" {
    try check("a = a or b", &.{
        .{ .tag = .get_var, .repr = 4 },
        .{ .tag = .or_then },
        .{ .tag = .get_var, .repr = 9 },
        .{ .tag = .or_end },
        .{ .tag = .set_var, .repr = 4 },
    });
}

const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Token = Ast.Token;
const Node = Ast.Node;

const std = @import("std");
const Ast = @import("Ast.zig");
const Tokenizer = @import("Tokenizer.zig");
