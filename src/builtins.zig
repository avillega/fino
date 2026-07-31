const std = @import("std");
const Vm = @import("Vm.zig");
const Value = Vm.Value;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const NativeError = error{ TargetMustBeArray, TooFewArgs } || Allocator.Error || Writer.Error;

pub const NativeFn = *const fn (vm: *Vm, args: []Value) NativeError!Value;

pub fn print(vm: *Vm, args: []Value) NativeError!Value {
    var i: u8 = 0;
    for (args) |arg| {
        if (i > 0) try vm.out.writeAll(" ");
        i += 1;
        try vm.out.print("{f}", .{arg.fmt(vm.interner)});
    }
    try vm.out.writeByte('\n');
    return .nil;
}

pub fn len(vm: *Vm, args: []Value) NativeError!Value {
    _ = vm;
    std.debug.assert(args.len == 1);
    const arg = args[0];
    const l = switch (arg) {
        .number => 0,
        .nil => 0,
        .atom => 0,
        .str => |s| s.buffer.len,
        .arr => |a| a.elems.items.len,
        .rec => |r| r.map.entries.len,
        .taken, .idx => unreachable,
    };
    return .{ .number = @floatFromInt(l) };
}

pub fn append(vm: *Vm, args: []Value) NativeError!Value {
    if (args.len < 2) return error.TooFewArgs;
    if (args[0] != .arr) return error.TargetMustBeArray;
    const result = try args[0].arr.ensureUnique(vm.gpa);
    args[0] = .nil;
    try result.elems.ensureUnusedCapacity(vm.gpa, args.len - 1);

    for (args[1..]) |e| {
        result.elems.appendAssumeCapacity(e.retain());
    }
    return .{ .arr = result };
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
