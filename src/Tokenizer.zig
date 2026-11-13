src: []const u8,
offset: u24 = 0,

pub fn init(src: []const u8) Tokenizer {
    assert(src.len < std.math.maxInt(u32));
    return .{
        .src = src,
        .offset = 0,
    };
}

fn byte(t: *Tokenizer) u8 {
    if (t.offset >= t.src.len) return 0;
    return t.src[t.offset];
}

pub fn lexeme(src: []const u8, token: Token) []const u8 {
    var t: Tokenizer = .{
        .src = src,
        .offset = token.offset,
    };
    _ = t.next();
    return src[token.offset..t.offset];
}

pub fn next(t: *Tokenizer) Token {
    if (t.offset >= t.src.len) return .{
        .tag = .eof,
        .offset = t.offset,
    };
    const State = enum(u8) {
        // zig fmt: off
        start, sep, number, number_dot,
        name, comment, string, err, atom,
        @".", @":", @"<", @">", @"=", @"!",
        // zig fmt: on
    };

    const state: State = .start;
    var result: Token = .{
        .tag = undefined,
        .offset = t.offset,
    };

    state: switch (state) {
        .start => switch (t.byte()) {
            0 => {
                if (t.offset >= t.src.len) {
                    return .{
                        .tag = .eof,
                        .offset = t.offset,
                    };
                }
                continue :state .err;
            },
            ' ', '\t', '\r' => {
                t.offset += 1;
                result.offset = t.offset;
                continue :state .start;
            },
            '\n', ';' => {
                t.offset += 1;
                result.offset = t.offset;
                continue :state .sep;
            },
            '"' => {
                result.tag = .string;
                continue :state .string;
            },
            'a'...'z', 'A'...'Z', '_' => {
                result.tag = .name;
                continue :state .name;
            },
            '0'...'9' => {
                result.tag = .number;
                continue :state .number;
            },
            '#' => continue :state .comment,
            ':' => continue :state .@":",
            '.' => continue :state .@".",
            '<' => continue :state .@"<",
            '>' => continue :state .@">",
            '=' => continue :state .@"=",
            '!' => continue :state .@"!",
            inline '(', ')', '{', '}', '[', ']', '+', '-', '*', '/', '%', '|', ',' => |tag| {
                result.tag = @field(Token.Tag, &.{tag});
                t.offset += 1;
            },
            else => continue :state .err,
        },
        .@"=" => {
            t.offset += 1;
            switch (t.byte()) {
                '=' => {
                    t.offset += 1;
                    result.tag = .@"==";
                },
                else => {
                    result.tag = .@"=";
                },
            }
        },
        .@"!" => {
            t.offset += 1;
            switch (t.byte()) {
                '=' => {
                    t.offset += 1;
                    result.tag = .@"!=";
                },
                else => {
                    result.tag = .@"!";
                },
            }
        },
        .@"<" => {
            t.offset += 1;
            switch (t.byte()) {
                '=' => {
                    t.offset += 1;
                    result.tag = .@"<=";
                },
                else => {
                    result.tag = .@"<";
                },
            }
        },
        .@">" => {
            t.offset += 1;
            switch (t.byte()) {
                '=' => {
                    t.offset += 1;
                    result.tag = .@">=";
                },
                else => {
                    result.tag = .@">";
                },
            }
        },
        .@"." => {
            t.offset += 1;
            switch (t.byte()) {
                '{' => {
                    t.offset += 1;
                    result.tag = .@".{";
                },
                else => result.tag = .err,
            }
        },
        .@":" => {
            t.offset += 1;
            switch (t.byte()) {
                '=' => {
                    t.offset += 1;
                    result.tag = .@":=";
                },
                else => continue :state .atom,
            }
        },
        .sep => {
            result.tag = .sep;
            t.offset += 1;
            switch (t.byte()) {
                '\n', ';' => {
                    continue :state .sep;
                },
                else => {},
            }
        },
        .comment => {
            t.offset += 1;
            switch (t.byte()) {
                '\n' => continue :state .start,
                else => continue :state .comment,
            }
        },
        .name => {
            t.offset += 1;
            switch (t.byte()) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .name,
                else => {
                    const name = t.src[result.offset..t.offset];
                    if (keyword(name)) |tag| result.tag = tag;
                },
            }
        },
        .atom => {
            t.offset += 1;
            switch (t.byte()) {
                'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .atom,
                else => result.tag = .atom,
            }
        },
        .string => {
            t.offset += 1;
            switch (t.byte()) {
                0, '\n' => result.tag = .err,
                '"' => t.offset += 1,
                else => continue :state .string,
            }
        },
        .number => {
            t.offset += 1;
            switch (t.byte()) {
                '0'...'9' => continue :state .number,
                '.' => continue :state .number_dot,
                else => {},
            }
        },
        .number_dot => {
            t.offset += 1;
            switch (t.byte()) {
                '0'...'9' => continue :state .number_dot,
                else => {},
            }
        },
        .err => {
            return .{
                .tag = .err,
                .offset = t.offset,
            };
        },
    }
    return result;
}
fn keyword(name: []const u8) ?Token.Tag {
    const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
        .{ "fn", .@"fn" },
        .{ "return", .@"return" },
        .{ "true", .true },
        .{ "false", .false },
        .{ "nil", .nil },
        .{ "while", .@"while" },
        .{ "for", .@"for" },
        .{ "and", .@"and" },
        .{ "or", .@"or" },
        .{ "if", .@"if" },
        .{ "else", .@"else" },
    });
    return keywords.get(name);
}

const Tokenizer = @This();

const Token = Ast.Token;
const assert = std.debug.assert;
const Ast = @import("Ast.zig");
const std = @import("std");
