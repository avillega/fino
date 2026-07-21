const std = @import("std");
const Vm = @import("Vm.zig");
const Value = Vm.Value;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const NativeError = error{ MustBeArray, TooFewArgs } || Allocator.Error || Writer.Error;

pub const NativeFn = *const fn (vm: *Vm, gpa: Allocator, args: []Value) NativeError!Value;

pub fn print(vm: *Vm, gpa: Allocator, args: []Value) NativeError!Value {
    _ = gpa;
    var i: u8 = 0;
    for (args) |arg| {
        if (i > 0) try vm.out.writeAll(" ");
        i += 1;
        try vm.out.print("{f}", .{arg});
    }
    try vm.out.writeByte('\n');
    return .nil;
}

pub fn len(vm: *Vm, gpa: Allocator, args: []Value) NativeError!Value {
    _ = gpa;
    _ = vm;
    std.debug.assert(args.len == 1);
    const arg = args[0];
    const l = switch (arg) {
        .int => 0,
        .nil => 0,
        .str => |s| s.buffer.len,
        .arr => |a| a.elems.items.len,
    };
    return .{ .int = @intCast(l) };
}

pub fn append(vm: *Vm, gpa: Allocator, args: []Value) NativeError!Value {
    _ = vm;
    if (args.len < 2) return error.TooFewArgs;
    var result = args[0];
    args[0] = .nil;
    if (result != .arr) return error.MustBeArray;

    for (args[1..]) |*e| {
        try result.arr.elems.append(gpa, e.*);
        e.* = .nil;
    }
    return result;
}

const NativeDef = struct {
    name: []const u8,
    call: NativeFn,
    arity: ?u8,
};

pub const builtins = [_]NativeDef{
    .{ .name = "print", .call = print, .arity = null },
    .{ .name = "len", .call = len, .arity = 1 },
    .{ .name = "append", .call = append, .arity = null },
};
