binding: struct {
    slot: []Slot,
    name_id: []u24,
    count: u32,
},

function: struct {
    pos: []u24,
    name_id: []u24,
    count: u32,
},

const Resolver = @This();
const empty: Resolver = .{
    .binding = .{
        .slot = &.{},
        .name_id = &.{},
        .count = 0,
    },
    .function = .{
        .pos = &.{},
        .name_id = &.{},
        .count = 0,
    },
};

const Binding = struct {
    slot: Slot,
    name_id: u24,
};

pub fn reserve(r: *Resolver, gpa: Allocator, capacity: struct { bindings: u32, functions: u32 }) !void {
    r.binding.slot = try gpa.alloc(Slot, capacity.bindings);
    r.binding.name_id = try gpa.alloc(u24, capacity.bindings);
    r.binding.count = 0;

    r.function.pos = try gpa.alloc(u24, capacity.functions);
    r.function.name_id = try gpa.alloc(u24, capacity.functions);
    r.function.count = 0;
}

pub fn deinit(r: *Resolver, gpa: Allocator) void {
    gpa.free(r.binding.slot);
    gpa.free(r.binding.name_id);
    r.binding.count = 0;

    gpa.free(r.function.pos);
    gpa.free(r.function.name_id);
    r.function.count = 0;
}

pub fn find_binding(r: *const Resolver, name_id: u24) ?Slot {
    var i = r.binding.count;
    while (i > 0) {
        i -= 1;
        const bn = r.binding.name_id[i];
        if (bn == name_id) {
            return r.binding.slot[i];
        }
    }
    return null;
}

pub fn find_fn_pos(r: *const Resolver, name_id: u24) ?u24 {
    var i = r.function.count;
    while (i > 0) {
        i -= 1;
        const f = r.function.name_id[i];
        if (f == name_id) {
            return r.function.pos[i];
        }
    }
    return null;
}
pub fn resolve(r: *Resolver, ast: *Ast) !void {
    try r.resolve_top(ast);
    try r.resolve_ini(ast);
    try r.flow_analysis(ast);
    ast.resolved = true;
}

fn resolve_top(r: *Resolver, ast: *Ast) !void {
    var depth: u16 = 0;
    var global_count: u24 = 0;
    for (ast.node.tag, 0..) |tag, i| {
        switch (tag) {
            .scope_begin, .for_do => depth += 1,
            .scope_end, .for_end => depth -= 1,
            .dec_var => if (depth == 0) {
                const b = r.find_binding(@intCast(ast.node.repr[i]));
                if (b != null) return error.global_redeclaration;
                try r.add_binding(@intCast(ast.node.repr[i]), global_count, .glob);
                global_count += 1;
                ast.node.repr[i] = @backingInt(r.binding.slot[r.binding.count - 1]);
            },
            .set_var, .get_var => if (depth == 0) {
                const b = r.find_binding(@intCast(ast.node.repr[i])) orelse {
                    return error.variable_not_declared;
                };
                ast.node.repr[i] = @backingInt(b);
            },
            .fn_begin => {
                assert(depth == 0);
                const f: Node.Fn = @fromBackingInt(ast.node.repr[i]);
                const f_pos = r.find_fn_pos(f.name_id);
                if (f_pos != null) return error.fn_redefinition;

                try r.add_fn(f.name_id, @intCast(i));
            },
            else => {},
        }
    }
}

fn resolve_ini(r: *Resolver, ast: *Ast) !void {
    var marks: [256]u32 = undefined;
    var marks_top: u8 = 0;

    var frame_cnt: u24 = 0;
    var prev_frame_cnt: u24 = 0;

    for (ast.node.tag, 0..) |tag, i| {
        switch (tag) {
            .scope_begin => {
                marks[marks_top] = r.binding.count;
                marks_top += 1;
            },
            .scope_end => {
                assert(marks_top > 0);
                marks_top -= 1;
                r.binding.count = marks[marks_top];
            },
            .dec_var => if (marks_top > 0) {
                try r.add_binding(@intCast(ast.node.repr[i]), frame_cnt, .locl);
                frame_cnt += 1;
                ast.node.repr[i] = @backingInt(r.binding.slot[r.binding.count - 1]);
            },
            .set_var, .get_var => if (marks_top > 0) {
                const b = r.find_binding(@intCast(ast.node.repr[i])) orelse {
                    return error.variable_not_declared;
                };
                ast.node.repr[i] = @backingInt(b);
            },
            .call => {
                const c_repr: Node.Fn = @fromBackingInt(ast.node.repr[i]);
                const f_pos = r.find_fn_pos(c_repr.name_id) orelse {
                    return error.fn_not_defined;
                };
                assert(ast.node.tag[f_pos] == .fn_begin);
                const f: Node = .{ .tag = ast.node.tag[f_pos], .repr = ast.node.repr[f_pos] };
                const f_repr: Node.Fn = @fromBackingInt(f.repr);

                if (f_repr.argc != c_repr.argc) return error.call_wrong_arity;
                ast.node.repr[i] = @backingInt(Node.Call{ .pos = f_pos, .argc = c_repr.argc });
            },
            .fn_begin => {
                assert(marks_top == 0);
                prev_frame_cnt = frame_cnt;
                frame_cnt = 0;
                marks[marks_top] = r.binding.count;
                marks_top += 1;
            },
            .dec_param => {
                try r.add_binding(@intCast(ast.node.repr[i]), frame_cnt, .locl);
                frame_cnt += 1;
                ast.node.repr[i] = @backingInt(r.binding.slot[r.binding.count - 1]);
            },
            .fn_end => {
                assert(marks_top == 1);
                frame_cnt = prev_frame_cnt;
                marks_top -= 1;
                r.binding.count = marks[marks_top];
            },
            .for_do => {
                marks[marks_top] = r.binding.count;
                marks_top += 1;
            },
            .dec_capture => {
                try r.add_binding(@intCast(ast.node.repr[i]), frame_cnt, .locl);
                frame_cnt += 1;
                ast.node.repr[i] = @backingInt(r.binding.slot[r.binding.count - 1]);
            },
            .for_end => {
                marks_top -= 1;
                r.binding.count = marks[marks_top];
            },
            else => {},
        }
    }
}

fn flow_analysis(r: *Resolver, ast: *Ast) !void {
    _ = r; // not using r yet, only a basic return position analysis
    var in_fn: bool = false;
    for (ast.node.tag) |tag| switch (tag) {
        .fn_begin => in_fn = true,
        .fn_end => in_fn = false,
        .ret => if (!in_fn) return error.return_must_be_in_fn,
        else => {},
    };
}

pub fn add_binding(r: *Resolver, name_id: u24, slot_id: u24, kind: SlotKind) !void {
    if (r.binding.count == r.binding.name_id.len) return error.oom;
    r.binding.name_id[r.binding.count] = name_id;
    r.binding.slot[r.binding.count] = .{
        .id = slot_id,
        .kind = kind,
    };
    r.binding.count += 1;
}

pub fn add_fn(r: *Resolver, name_id: u24, pos: u24) !void {
    if (r.function.count == r.function.pos.len) return error.oom;
    r.function.pos[r.function.count] = pos;
    r.function.name_id[r.function.count] = name_id;
    r.function.count += 1;
}

fn check(src: []const u8, expected: []const Node) !void {
    var p: Parser = .empty;
    try p.reserve(std.testing.allocator, .{ .nodes = 256, .tokens = 256, .strings = 256 });
    defer p.deinit(std.testing.allocator);
    defer std.testing.allocator.free(p.node.tag);
    defer std.testing.allocator.free(p.node.repr);

    var r: Resolver = .empty;
    try r.reserve(std.testing.allocator, .{ .bindings = 256, .functions = 128 });
    defer r.deinit(std.testing.allocator);

    try p.parse(src);
    var ast = p.ast();
    try r.resolve(&ast);
    const actual = try ast.node_slice(std.testing.allocator);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(Node, expected, actual);
}

fn check_err(src: []const u8, expected: anyerror) !void {
    var p: Parser = .empty;
    try p.reserve(std.testing.allocator, .{ .nodes = 256, .tokens = 256, .strings = 256 });
    defer p.deinit(std.testing.allocator);
    defer std.testing.allocator.free(p.node.tag);
    defer std.testing.allocator.free(p.node.repr);

    var r: Resolver = .empty;
    try r.reserve(std.testing.allocator, .{ .bindings = 256, .functions = 128 });
    defer r.deinit(std.testing.allocator);

    try p.parse(src);
    var ast = p.ast();
    try std.testing.expectError(expected, r.resolve(&ast));
}

test "resolve globals" {
    const s =
        \\ x := 1
        \\ y := x
    ;
    try check(s, &.{
        .{ .tag = .num, .repr = 6 },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 1, .kind = .glob }) },
    });
}

test "resolve locals in top level block" {
    const s =
        \\ x := 1
        \\ {y := x; y = 2}
    ;
    try check(s, &.{
        .{ .tag = .num, .repr = 6 },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .scope_begin },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .num, .repr = 22 },
        .{ .tag = .set_var, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .scope_end },
    });
}

test "variables correctly go out of scope" {
    const s =
        \\ x := 1
        \\ {y := x; y = 2}
        \\ z := y
    ;
    try check_err(s, error.variable_not_declared);
}

test "resolve: fn locals" {
    const s =
        \\ x := 10
        \\ fn my_fn(x, y) {z := y; w := x; x = z}
    ;
    try check(s, &.{
        .{ .tag = .num, .repr = 6 },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .fn_begin, .repr = @backingInt(Node.Fn{ .name_id = 13, .argc = 2 }) },
        .{ .tag = .dec_param, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .dec_param, .repr = @backingInt(Slot{ .id = 1, .kind = .locl }) },
        .{ .tag = .scope_begin, .repr = 0 },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 1, .kind = .locl }) },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 2, .kind = .locl }) },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 3, .kind = .locl }) },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 2, .kind = .locl }) },
        .{ .tag = .set_var, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .scope_end, .repr = 0 },
        .{ .tag = .fn_end, .repr = 0 },
    });
}

test "resolve: call" {
    const s =
        \\ fn my_fn(x, y) {return x == y}
        \\ my_fn(10, 10)
    ;
    try check(s, &.{
        .{ .tag = .fn_begin, .repr = @backingInt(Node.Fn{ .name_id = 4, .argc = 2 }) },
        .{ .tag = .dec_param, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .dec_param, .repr = @backingInt(Slot{ .id = 1, .kind = .locl }) },
        .{ .tag = .scope_begin, .repr = 0 },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 1, .kind = .locl }) },
        .{ .tag = .eql },
        .{ .tag = .ret },
        .{ .tag = .scope_end },
        .{ .tag = .fn_end },
        .{ .tag = .num, .repr = 39 },
        .{ .tag = .num, .repr = 43 },
        .{ .tag = .call, .repr = @backingInt(Node.Call{ .pos = 0, .argc = 2 }) },
        .{ .tag = .discard },
    });
}

test "resolve: call with wrong number of args" {
    const s =
        \\ fn my_fn(x, y) {return x == y}
        \\ my_fn(10, 10, 10)
    ;
    try check_err(s, error.call_wrong_arity);
}

test "resolve: for" {
    const s =
        \\ arr := []
        \\ for (arr) |a| { a = 1 }
    ;
    try check(s, &.{
        .{ .tag = .arr, .repr = 0 },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .for_do, .repr = 0 },
        .{ .tag = .dec_capture, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .scope_begin, .repr = 0 },
        .{ .tag = .num, .repr = 32 },
        .{ .tag = .set_var, .repr = @backingInt(Slot{ .id = 0, .kind = .locl }) },
        .{ .tag = .scope_end, .repr = 0 },
        .{ .tag = .for_end, .repr = 1 },
    });
}

test "resolve: simple while" {
    const s =
        \\ i := 0
        \\ while i < 10 { i = i + 1 }
    ;
    try check(s, &.{
        .{ .tag = .num, .repr = 6 },
        .{ .tag = .dec_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .while_begin },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .num, .repr = 19 },
        .{ .tag = .lt },
        .{ .tag = .while_do },
        .{ .tag = .scope_begin },
        .{ .tag = .get_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .num, .repr = 32 },
        .{ .tag = .add },
        .{ .tag = .set_var, .repr = @backingInt(Slot{ .id = 0, .kind = .glob }) },
        .{ .tag = .scope_end },
        .{ .tag = .while_end },
    });
}

test "flow: ret not in function" {
    const s = "{return 1}";
    try check_err(s, error.return_must_be_in_fn);
}

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Slot = Node.Slot;
const SlotKind = Node.SlotKind;
const Node = Ast.Node;
const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const std = @import("std");
