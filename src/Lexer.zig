const std = @import("std");
const Io = std.Io;

const Lexer = @This();

curr: u32,
src: [:0]const u8,

pub const Token = struct {
    tag: Tag,
    start: u32,
    end: u32,
    pub const Tag = enum {
        oparen,
        cparen,
        obrace,
        cbrace,
        obracket,
        cbracket,
        eql,
        bang,
        comma,
        plus,
        minus,
        star,
        slash,
        mod,
        lt,
        gt,
        sep,
        integer,

        eql_eql,
        bang_eql,
        lt_eql,
        gt_eql,

        kw_fn,
        kw_return,
        kw_true,
        kw_false,
        kw_var,
        kw_nil,
        kw_if,
        kw_else,
        kw_while,
        str_lit,
        identifier,
        err,
        eof,
    };

    pub fn lexeme(t: Token, src: [:0]const u8) []const u8 {
        return src[t.start..t.end];
    }
};

pub fn init(source: [:0]const u8) Lexer {
    return .{ .src = source, .curr = 0 };
}

const keywords: std.StaticStringMap(Token.Tag) = .initComptime(.{
    .{ "fn", .kw_fn },
    .{ "return", .kw_return },
    .{ "true", .kw_true },
    .{ "false", .kw_false },
    .{ "var", .kw_var },
    .{ "nil", .kw_nil },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
});

fn identTag(lexeme: []const u8) Token.Tag {
    return keywords.get(lexeme) orelse .identifier;
}

pub fn next(self: *Lexer) Token {
    const State = enum {
        start,
        eql,
        lt,
        gt,
        bang,
        ident,
        integ,
        str,
    };

    var start = self.curr;

    sw: switch (State.start) {
        .start => {
            var tag: Token.Tag = undefined;
            switch (self.src[self.curr]) {
                0 => {
                    return .{ .tag = .eof, .start = start, .end = self.curr };
                },
                ' ', '\t', '\r' => {
                    self.curr += 1;
                    start += 1;
                    continue :sw .start;
                },
                '\n', ';' => {
                    tag = .sep;
                },
                '{' => {
                    tag = .obrace;
                },
                '}' => {
                    tag = .cbrace;
                },
                '(' => {
                    tag = .oparen;
                },
                ')' => {
                    tag = .cparen;
                },
                ',' => {
                    tag = .comma;
                },
                '+' => {
                    tag = .plus;
                },
                '-' => {
                    tag = .minus;
                },
                '*' => {
                    tag = .star;
                },
                '/' => {
                    tag = .slash;
                },
                '%' => {
                    tag = .mod;
                },
                '[' => {
                    tag = .obracket;
                },
                ']' => {
                    tag = .cbracket;
                },
                '=' => {
                    self.curr += 1;
                    continue :sw .eql;
                },
                '!' => {
                    self.curr += 1;
                    continue :sw .bang;
                },
                '<' => {
                    self.curr += 1;
                    continue :sw .lt;
                },
                '>' => {
                    self.curr += 1;
                    continue :sw .gt;
                },
                '"' => {
                    self.curr += 1;
                    continue :sw .str;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    self.curr += 1;
                    continue :sw .ident;
                },
                '0'...'9' => {
                    self.curr += 1;
                    continue :sw .integ;
                },
                else => {
                    std.debug.panic("unhandled char {c}", .{self.src[self.curr]});
                },
            }

            self.curr += 1;
            return .{ .tag = tag, .start = start, .end = self.curr };
        },
        .eql => {
            const tag: Token.Tag = if (self.matchCurr('=')) .eql_eql else .eql;
            return .{ .tag = tag, .start = start, .end = self.curr };
        },
        .lt => {
            const tag: Token.Tag = if (self.matchCurr('=')) .lt_eql else .lt;
            return .{ .tag = tag, .start = start, .end = self.curr };
        },
        .gt => {
            const tag: Token.Tag = if (self.matchCurr('=')) .gt_eql else .gt;
            return .{ .tag = tag, .start = start, .end = self.curr };
        },
        .bang => {
            const tag: Token.Tag = if (self.matchCurr('=')) .bang_eql else .bang;
            return .{ .tag = tag, .start = start, .end = self.curr };
        },
        .ident => {
            switch (self.src[self.curr]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                    self.curr += 1;
                    continue :sw .ident;
                },
                else => {},
            }

            const lexeme = self.src[start..self.curr];
            return .{ .tag = identTag(lexeme), .start = start, .end = self.curr };
        },
        .integ => {
            switch (self.src[self.curr]) {
                '0'...'9' => {
                    self.curr += 1;
                    continue :sw .integ;
                },
                else => {},
            }
            return .{ .tag = .integer, .start = start, .end = self.curr };
        },
        .str => {
            switch (self.src[self.curr]) {
                0 => {
                    return .{ .tag = .err, .start = start, .end = self.curr };
                },
                '"' => {
                    const end = self.curr;
                    start += 1; // don't put the " in the string
                    self.curr += 1;
                    return .{ .tag = .str_lit, .start = start, .end = end };
                },
                else => {
                    self.curr += 1;
                    continue :sw .str;
                },
            }
        },
    }
}

fn matchCurr(self: *Lexer, b: u8) bool {
    if (self.src[self.curr] == b) {
        self.curr += 1;
        return true;
    }
    return false;
}

pub fn printTokens(w: *Io.Writer, lexer: *Lexer) !void {
    while (true) {
        const t = lexer.next();
        switch (t.tag) {
            .sep => try w.print("sep \"{c}\"\n", .{lexer.src[t.start]}),
            else => try w.print("{t} \"{s}\"\n", .{ t.tag, t.lexeme(lexer.src) }),
        }
        if (t.tag == .eof) break;
    }
}

test "basic lexing" {
    const t = std.testing;
    var lex = Lexer.init("(){}fn return");

    try t.expectEqual(.oparen, lex.next().tag);
    try t.expectEqual(.cparen, lex.next().tag);
    try t.expectEqual(.obrace, lex.next().tag);
    try t.expectEqual(.cbrace, lex.next().tag);
    try t.expectEqual(.kw_fn, lex.next().tag);
    try t.expectEqual(.kw_return, lex.next().tag);
    try t.expectEqual(.eof, lex.next().tag);
}

fn expectToken(src: [:0]const u8, tok: Token, tag: Token.Tag, expected: []const u8) !void {
    const t = std.testing;
    try t.expectEqual(tag, tok.tag);
    try t.expectEqualStrings(expected, tok.lexeme(src));
}

test "fn lexing" {
    const t = std.testing;
    const src =
        \\ fn main(x,y) {
        \\     return x
        \\ }
    ;
    var lex = Lexer.init(src);

    try t.expectEqual(.kw_fn, lex.next().tag);
    try expectToken(src, lex.next(), .identifier, "main");
    try t.expectEqual(.oparen, lex.next().tag);
    try expectToken(src, lex.next(), .identifier, "x");
    try t.expectEqual(.comma, lex.next().tag);
    try expectToken(src, lex.next(), .identifier, "y");
    try t.expectEqual(.cparen, lex.next().tag);
    try t.expectEqual(.obrace, lex.next().tag);
    try t.expectEqual(.sep, lex.next().tag);
    try t.expectEqual(.kw_return, lex.next().tag);
    try expectToken(src, lex.next(), .identifier, "x");
    try t.expectEqual(.sep, lex.next().tag);
    try t.expectEqual(.cbrace, lex.next().tag);
    try t.expectEqual(.eof, lex.next().tag);
}

test "identifiers lexing" {
    const t = std.testing;
    const src = "xyz a_b_c a0 areturnfn a9 return";
    var lex = Lexer.init(src);

    try expectToken(src, lex.next(), .identifier, "xyz");
    try expectToken(src, lex.next(), .identifier, "a_b_c");
    try expectToken(src, lex.next(), .identifier, "a0");
    try expectToken(src, lex.next(), .identifier, "areturnfn");
    try expectToken(src, lex.next(), .identifier, "a9");
    const ret = lex.next();
    try t.expectEqual(.kw_return, ret.tag);
    try t.expectEqualStrings("return", ret.lexeme(src));
    try t.expectEqual(.eof, lex.next().tag);
}

test "empty input is eof" {
    var lex = Lexer.init("");
    try std.testing.expectEqual(.eof, lex.next().tag);
}

test "all keywords" {
    const t = std.testing;
    const src = "fn return print true false var";
    var lex = Lexer.init(src);

    try expectToken(src, lex.next(), .kw_fn, "fn");
    try expectToken(src, lex.next(), .kw_return, "return");
    try expectToken(src, lex.next(), .identifier, "print");
    try expectToken(src, lex.next(), .kw_true, "true");
    try expectToken(src, lex.next(), .kw_false, "false");
    try expectToken(src, lex.next(), .kw_var, "var");
    try t.expectEqual(.eof, lex.next().tag);
}

test "whitespace-only input is eof" {
    var lex = Lexer.init("   \t\r  ");
    try std.testing.expectEqual(.eof, lex.next().tag);
}

test "keywords vs identifiers" {
    const t = std.testing;
    const src = "fn fnx _fn fn_ Fn return0 _return";
    var lex = Lexer.init(src);

    try t.expectEqual(.kw_fn, lex.next().tag);
    try expectToken(src, lex.next(), .identifier, "fnx");
    try expectToken(src, lex.next(), .identifier, "_fn");
    try expectToken(src, lex.next(), .identifier, "fn_");
    try expectToken(src, lex.next(), .identifier, "Fn");
    try expectToken(src, lex.next(), .identifier, "return0");
    try expectToken(src, lex.next(), .identifier, "_return");
    try t.expectEqual(.eof, lex.next().tag);
}

test "integers and identfiers" {
    const t = std.testing;
    const src = "100 a100 _100 1 a1";
    var lex = Lexer.init(src);

    try expectToken(src, lex.next(), .integer, "100");
    try expectToken(src, lex.next(), .identifier, "a100");
    try expectToken(src, lex.next(), .identifier, "_100");
    try expectToken(src, lex.next(), .integer, "1");
    try expectToken(src, lex.next(), .identifier, "a1");
    try t.expectEqual(.eof, lex.next().tag);
}

test "operators" {
    const t = std.testing;
    const src = "100 + a - b * c / d";
    var lex = Lexer.init(src);

    try expectToken(src, lex.next(), .integer, "100");
    try expectToken(src, lex.next(), .plus, "+");
    try expectToken(src, lex.next(), .identifier, "a");
    try expectToken(src, lex.next(), .minus, "-");
    try expectToken(src, lex.next(), .identifier, "b");
    try expectToken(src, lex.next(), .star, "*");
    try expectToken(src, lex.next(), .identifier, "c");
    try expectToken(src, lex.next(), .slash, "/");
    try expectToken(src, lex.next(), .identifier, "d");
    try t.expectEqual(.eof, lex.next().tag);
}

test "two char operators" {
    const t = std.testing;
    const src = "100 == 10 != b <= c >= d; var x = y";
    var lex = Lexer.init(src);

    try expectToken(src, lex.next(), .integer, "100");
    try expectToken(src, lex.next(), .eql_eql, "==");
    try expectToken(src, lex.next(), .integer, "10");
    try expectToken(src, lex.next(), .bang_eql, "!=");
    try expectToken(src, lex.next(), .identifier, "b");
    try expectToken(src, lex.next(), .lt_eql, "<=");
    try expectToken(src, lex.next(), .identifier, "c");
    try expectToken(src, lex.next(), .gt_eql, ">=");
    try expectToken(src, lex.next(), .identifier, "d");
    try expectToken(src, lex.next(), .sep, ";");
    try expectToken(src, lex.next(), .kw_var, "var");
    try expectToken(src, lex.next(), .identifier, "x");
    try expectToken(src, lex.next(), .eql, "=");
    try expectToken(src, lex.next(), .identifier, "y");
    try t.expectEqual(.eof, lex.next().tag);
}

test "lex if" {
    const t = std.testing;
    const src = "if (true) { return } else {return}";
    var lex = Lexer.init(src);

    try expectToken(src, lex.next(), .kw_if, "if");
    try expectToken(src, lex.next(), .oparen, "(");
    try expectToken(src, lex.next(), .kw_true, "true");
    try expectToken(src, lex.next(), .cparen, ")");
    try expectToken(src, lex.next(), .obrace, "{");
    try expectToken(src, lex.next(), .kw_return, "return");
    try expectToken(src, lex.next(), .cbrace, "}");
    try expectToken(src, lex.next(), .kw_else, "else");
    try expectToken(src, lex.next(), .obrace, "{");
    try expectToken(src, lex.next(), .kw_return, "return");
    try expectToken(src, lex.next(), .cbrace, "}");
    try t.expectEqual(.eof, lex.next().tag);
}

test "lex while" {
    const t = std.testing;
    const src = "while (true) { return }";
    var lex = Lexer.init(src);

    try expectToken(src, lex.next(), .kw_while, "while");
    try expectToken(src, lex.next(), .oparen, "(");
    try expectToken(src, lex.next(), .kw_true, "true");
    try expectToken(src, lex.next(), .cparen, ")");
    try expectToken(src, lex.next(), .obrace, "{");
    try expectToken(src, lex.next(), .kw_return, "return");
    try expectToken(src, lex.next(), .cbrace, "}");
    try t.expectEqual(.eof, lex.next().tag);
}

test "lex string literal" {
    const t = std.testing;
    const src =
        \\ a = "my_string/lit"
        \\
    ;
    var lex = Lexer.init(src);
    try expectToken(src, lex.next(), .identifier, "a");
    try expectToken(src, lex.next(), .eql, "=");
    try expectToken(src, lex.next(), .str_lit, "my_string/lit");
    try t.expectEqual(.sep, lex.next().tag);
    try t.expectEqual(.eof, lex.next().tag);
}

test "lex array literal" {
    const t = std.testing;
    const src =
        \\ a = [x, y , z]
        \\
    ;
    var lex = Lexer.init(src);
    try expectToken(src, lex.next(), .identifier, "a");
    try expectToken(src, lex.next(), .eql, "=");
    try expectToken(src, lex.next(), .obracket, "[");
    try expectToken(src, lex.next(), .identifier, "x");
    try expectToken(src, lex.next(), .comma, ",");
    try expectToken(src, lex.next(), .identifier, "y");
    try expectToken(src, lex.next(), .comma, ",");
    try expectToken(src, lex.next(), .identifier, "z");
    try expectToken(src, lex.next(), .cbracket, "]");
    try t.expectEqual(.sep, lex.next().tag);
    try t.expectEqual(.eof, lex.next().tag);
}
