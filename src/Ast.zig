src: []const u8,
node: struct {
    tag: []Node.Tag,
    repr: []u32,
},
resolved: bool = false,

pub const Ast = @This();

pub const Token = struct {
    tag: Token.Tag,
    // the max file size is 15 MiB, u24 is enough for that, we can use the offset
    // directly as the interned id.
    offset: u24,

    pub const Tag = enum(u8) {
        // zig fmt: off
        sep, // ; \n
        number, string, atom, name, err, eof, nil,
        @"(", @")", @"{", @".{", @"}", @"[", @"]" , @"=", @"==", @"!", @"!=", 
        @"+", @"-", @"*", @"/" , @"%", @"<", @"<=", @">", @">=", @",", @"|", 
        @":=",
        //keywords
        @"fn", @"return", true, false,
        @"while", @"for", @"and", @"or", @"if", @"else",
        // zig fmt: on
    };
};

pub const Node = struct {
    tag: Tag,
    repr: u32 = 0,

    pub const Fn = packed struct(u32) { name_id: u24, argc: u8 };
    pub const Call = packed struct(u32) { pos: u24, argc: u8 };
    pub const Slot = packed struct(u32) { kind: SlotKind, id: u24 };

    pub const SlotKind = enum(u8) {
        glob,
        locl,
    };
    pub const Tag = enum(u8) {
        // zig fmt: off
        // literals
        nil, num, atom, str, arr, record,
        // variables
        dec_param, dec_capture, dec_var, set_var, get_var, take_var,
        // unary expr
        neg, not,
        // binary expr
        add, sub, mul, div, mod, eql, lt, gt,
        // indexing operations
        get_idx, set_idx,
        // function related
        call, ret,
        // markers
        scope_begin, scope_end,
        fn_begin, fn_end, // this should use fun repr
        if_then, if_else, if_end_else, if_end,
        and_then, and_end,
        or_then, or_end,
        while_begin, while_do, while_end,
        for_do, for_end,

        discard,
        // zig fmt: on
    };
    pub fn print_parsed(node: @This(), src: []const u8, w: *Io.Writer) !void {
        switch (node.tag) {
            .num,
            .str,
            .atom,
            .dec_param,
            .dec_capture,
            .dec_var,
            .set_var,
            .get_var,
            .take_var,
            => try w.print("{{.tag = {any}, .repr = {s}}}\n", .{
                node.tag,
                lexeme(src, @intCast(node.repr)),
            }),
            .call, .fn_begin => {
                const f: Node.Fn = @fromBackingInt(node.repr);
                const name = lexeme(src, f.name_id);
                try w.print("{{.tag = {any}, .repr = {s}/{d}}}\n", .{
                    node.tag,
                    name,
                    f.argc,
                });
            },
            .for_end => try w.print("{{.tag = {any}, .captrures = {d}}}\n", .{ node.tag, node.repr }),
            inline else => |t| try w.print("{{.tag = {any}}}\n", .{t}),
        }
    }

    pub fn print_resolved(node: @This(), src: []const u8, w: *Io.Writer) !void {
        switch (node.tag) {
            .num,
            .str,
            .atom,
            => try w.print("{{.tag = {any}, .repr = {s}}}\n", .{
                node.tag,
                lexeme(src, @intCast(node.repr)),
            }),
            .dec_param,
            .dec_capture,
            .dec_var,
            .get_var,
            .set_var,
            .take_var,
            => {
                const s: Node.Slot = @fromBackingInt(node.repr);
                const k: []const u8 = switch (s.kind) {
                    .glob => "g",
                    .locl => "l",
                };
                try w.print("{{.tag = {any}, .repr = {s}{d}}}\n", .{
                    node.tag,
                    k,
                    s.id,
                });
            },
            .call => {
                const f: Node.Call = @fromBackingInt(node.repr);
                const name = lexeme(src, f.pos);
                try w.print("{{.tag = {any}, .repr = call {s}/{d}}}\n", .{
                    node.tag,
                    name,
                    f.argc,
                });
            },
            .fn_begin => {
                const f: Node.Fn = @fromBackingInt(node.repr);
                const name = lexeme(src, f.name_id);
                try w.print("{{.tag = {any}, .repr = {s}/{d}}}\n", .{
                    node.tag,
                    name,
                    f.argc,
                });
            },
            .for_end => try w.print("{{.tag = {any}, .captrures = {d}}}\n", .{ node.tag, node.repr }),
            inline else => |t| try w.print("{{.tag = {any}}}\n", .{t}),
        }
    }
};

pub fn debug_print(ast: *const Ast, stage: enum { parse, resolve }) void {
    var buffer: [256]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    if (stage == .parse) {
        for (ast.node.tag, ast.node.repr) |tag, repr| {
            const node: Node = .{ .tag = tag, .repr = repr };
            node.print_parsed(ast.src, &stderr.file_writer.interface) catch @panic("unable to write");
        }
    } else {
        for (ast.node.tag, ast.node.repr) |tag, repr| {
            const node: Node = .{ .tag = tag, .repr = repr };
            node.print_resolved(ast.src, &stderr.file_writer.interface) catch @panic("unable to write");
        }
    }
}

fn lexeme(src: []const u8, offset: u24) []const u8 {
    var t: Tokenizer = .{
        .src = src,
        .offset = offset,
    };
    _ = t.next();
    return src[offset..t.offset];
}

// used for testing mostly
pub fn node_slice(ast: *const Ast, gpa: std.mem.Allocator) ![]Node {
    var res: []Node = try gpa.alloc(Node, ast.node.tag.len);
    var count: u32 = 0;
    for (ast.node.tag, ast.node.repr) |tag, repr| {
        res[count] = .{ .tag = tag, .repr = repr };
        count += 1;
    }
    return res;
}

const assert = std.debug.assert;
const Io = std.Io;
const Tokenizer = @import("Tokenizer.zig");
const std = @import("std");
