const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const compiler = @import("compiler.zig");
const Parser = @import("Parser.zig");
const Lexer = @import("../Lexer.zig");
const Vm = @import("../Vm.zig");
const builtins = @import("../builtins.zig");
const Interner = @import("../Interner.zig");

const Program = @This();

gpa: Allocator,
interner: Interner,
insts: std.ArrayList(Vm.Inst),
fn_map: std.AutoHashMapUnmanaged(u24, u24),
fn_table: std.ArrayList(Vm.FnInfo),

pub fn init(gpa: Allocator) !Program {
    var program: Program = .{
        .gpa = gpa,
        .interner = .init(gpa),
        .insts = .empty,
        .fn_map = .empty,
        .fn_table = .empty,
    };
    try program.loadBuiltins();
    return program;
}

pub fn deinit(self: *Program) void {
    self.fn_map.deinit(self.gpa);
    self.fn_table.deinit(self.gpa);
    self.insts.deinit(self.gpa);
    self.interner.deinit();
}

pub fn loadBuiltins(self: *Program) !void {
    for (builtins.builtins) |b| {
        const id = try self.interner.intern_s(b.name);
        if (self.fn_map.contains(id)) return error.DuplicatedFn;
        try self.fn_map.put(self.gpa, id, @intCast(self.fn_table.items.len));
        try self.fn_table.append(self.gpa, .{
            .name_id = id,
            .arity = b.arity,
            .body = .{ .native = b.call },
        });
    }
}

pub fn run(prog: *Program, vm: *Vm, src: [:0]const u8) !void {
    var parser: Parser = .init(src, &prog.interner);
    const ast = parser.parse(prog.gpa) catch |err| {
        const serr = parser.err orelse "";
        try vm.out.print("{t} {s}\n", .{ err, serr });
        return;
    };
    defer prog.gpa.free(ast);

    const start = try compiler.compile(prog, ast);

    try vm.interpret(
        prog.gpa,
        start,
        prog.insts.items,
        &prog.interner,
        prog.fn_table.items,
    );
    try vm.out.flush();
}

pub fn benchParser(prog: *Program, src: [:0]const u8) !void {
    var parser: Parser = .init(src, &prog.interner);
    const ast = try parser.parse(prog.gpa);
    defer prog.gpa.free(ast);

    _ = try compiler.compile(prog, ast);
}

pub fn printInsts(prog: *Program, w: *Io.Writer, src: [:0]const u8) !void {
    var parser: Parser = .init(src, &prog.interner);
    const ast = parser.parse(prog.gpa) catch |err| {
        const serr = parser.err orelse "";
        try w.print("{t} {s}\n", .{ err, serr });
        return;
    };
    defer prog.gpa.free(ast);

    const start = try compiler.compile(prog, ast);

    const width = if (prog.insts.items.len == 0) 1 else std.math.log10(prog.insts.items.len) + 1;

    for (prog.insts.items[start..], start..) |it, idx| {
        try w.print("{[line]d: >[width]}│ {[instruction]f}\n", .{
            .width = width,
            .line = idx,
            .instruction = it,
        });
    }
    try w.flush();
}

test {
    _ = Lexer;
    _ = Parser;
    _ = Vm;
    _ = Interner;
    _ = compiler;
}

test "run: string litereral flow end-to-end" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var prog: Program = try .init(gpa);
    defer prog.deinit();
    var vm: Vm = .init(&w);
    defer vm.deinit(gpa);

    try prog.run(&vm,
        \\var s = "hello"
        \\print(s)
        \\print("a" == "a")
        \\print("a" == "b")
    );
    try std.testing.expectEqualStrings("hello\n1\n0\n", w.buffered());
}

test "run: string literals concat" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var prog: Program = try .init(gpa);
    defer prog.deinit();
    var vm: Vm = .init(&w);
    defer vm.deinit(gpa);

    try prog.run(&vm,
        \\var s = "hello"
        \\print(s)
        \\print(s + "world")
        \\s = " world"
        \\var y = "hello"
        \\print(y + s)
    );
    try std.testing.expectEqualStrings("hello\nhelloworld\nhello world\n", w.buffered());
}

test "run: arrays append" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var prog: Program = try .init(gpa);
    defer prog.deinit();
    var vm: Vm = .init(&w);
    defer vm.deinit(gpa);

    try prog.run(&vm,
        \\var s = [1]
        \\print(s)
        \\s = append(s, 2)
        \\s = append(s, 3)
        \\print(s)
    );
    try std.testing.expectEqualStrings("[1]\n[1, 2, 3]\n", w.buffered());
}

test "run: arrays concat" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var prog: Program = try .init(gpa);
    defer prog.deinit();
    var vm: Vm = .init(&w);
    defer vm.deinit(gpa);

    try prog.run(&vm,
        \\var s = [1]
        \\print(s)
        \\var a = [2, 3]
        \\print(s, a)
        \\var x = s + a
        \\print(s, a, x)
    );
    try std.testing.expectEqualStrings("[1]\n[1] [2, 3]\n[1] [2, 3] [1, 2, 3]\n", w.buffered());
}

test "run: arrays append to new array" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var prog: Program = try .init(gpa);
    defer prog.deinit();
    var vm: Vm = .init(&w);
    defer vm.deinit(gpa);

    try prog.run(&vm,
        \\var s = [1]
        \\print(s)
        \\var a = append(s, 2)
        \\print(s, a)
    );
    try std.testing.expectEqualStrings("[1]\n[1] [1, 2]\n", w.buffered());
}

test "run: program state persists across runs" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var prog: Program = try .init(gpa);
    defer prog.deinit();
    var vm: Vm = .init(&w);
    defer vm.deinit(gpa);

    // functions and globals from earlier runs stay usable the repl scenario
    try prog.run(&vm, "fn add(a, b) { return a + b }");
    try prog.run(&vm, "var x = 40");
    try prog.run(&vm, "print(add(x, 2))");
    try std.testing.expectEqualStrings("42\n", w.buffered());
}

test "run: array indexing" {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);

    var prog: Program = try .init(gpa);
    defer prog.deinit();
    var vm: Vm = .init(&w);
    defer vm.deinit(gpa);

    try prog.run(&vm,
        \\var x = [1, 2, 3]
        \\print(x[0])
        \\print(x[1])
    );
    try std.testing.expectEqualStrings("1\n2\n", w.buffered());
}
