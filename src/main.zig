const MiB = 1 << 20;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdin_reader = Io.File.stdin().reader(io, &.{});
    const stdin = &stdin_reader.interface;
    _ = stdin;

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer assert(stdout.end == 0);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    _ = args;

    const text_buffer = try gpa.alloc(u8, 15 * MiB);
    @memset(text_buffer, 0);
    defer gpa.free(text_buffer);

    var p: Parser = .empty;
    try p.reserve(gpa, .{
        .tokens = 30 << 20,
        .nodes = 30 << 20,
        .strings = 30 << 20,
    });

    try p.parse(text_buffer);

    try stdout.flush();
}

test {
    _ = Parser;
    _ = Resolver;
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

const assert = std.debug.assert;
const Io = std.Io;

const Parser = @import("Parser.zig");
const Resolver = @import("Resolver.zig");
const std = @import("std");
