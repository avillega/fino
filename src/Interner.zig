const std = @import("std");
const Allocator = std.mem.Allocator;
const Interner = @This();

const F64Context = struct {
    pub fn hash(self: @This(), key: f64) u64 {
        _ = self;
        if (key == 0.0) return 0;
        if (std.math.isNan(key)) return @bitCast(std.math.nan(f64));
        return @bitCast(key);
    }

    pub fn eql(self: @This(), a: f64, b: f64) bool {
        _ = self;
        if (std.math.isNan(a) and std.math.isNan(b)) return true;
        return a == b;
    }
};

gpa: Allocator,
string_arena: std.heap.ArenaAllocator,
string_map: std.StringHashMapUnmanaged(u24),
strings: std.ArrayList([]const u8),

consts_map: std.HashMapUnmanaged(f64, u24, F64Context, std.hash_map.default_max_load_percentage),
consts: std.ArrayList(f64),

pub fn init(gpa: Allocator) Interner {
    return .{
        .gpa = gpa,
        .string_arena = .init(gpa),
        .string_map = .empty,
        .strings = .empty,

        .consts_map = .empty,
        .consts = .empty,
    };
}

pub fn deinit(self: *Interner) void {
    self.string_map.deinit(self.gpa);
    self.strings.deinit(self.gpa);
    self.string_arena.deinit();
    self.consts.deinit(self.gpa);
    self.consts_map.deinit(self.gpa);
}

pub fn intern_s(self: *Interner, s: []const u8) !u24 {
    const gop = try self.string_map.getOrPut(self.gpa, s);
    if (gop.found_existing) return gop.value_ptr.*;

    const ns = try self.string_arena.allocator().dupe(u8, s);
    gop.key_ptr.* = ns;
    gop.value_ptr.* = @intCast(self.strings.items.len);
    try self.strings.append(self.gpa, ns);
    return gop.value_ptr.*;
}

pub fn intern_i(self: *Interner, i: f64) !u24 {
    const gop = try self.consts_map.getOrPut(self.gpa, i);
    if (gop.found_existing) return gop.value_ptr.*;

    gop.key_ptr.* = i;
    gop.value_ptr.* = @intCast(self.consts.items.len);
    try self.consts.append(self.gpa, i);
    return gop.value_ptr.*;
}

pub fn get_s(self: *const Interner, id: u24) ![]const u8 {
    if (id >= self.strings.items.len) return error.StringDoesNotExists;

    return self.strings.items[id];
}

pub fn get_i(self: *const Interner, id: u24) !f64 {
    if (id >= self.consts.items.len) return error.ConstDoesNotExists;

    return self.consts.items[id];
}

test "interner: correctly dupes the bytes to intern" {
    const t = std.testing;
    var buf: [11]u8 = "hello world".*;
    const alloc = std.testing.allocator;

    var interner: Interner = .init(alloc);
    defer interner.deinit();

    const hello = buf[0..5];

    const g = try interner.intern_s(hello);
    try t.expectEqual(g, 0);

    buf[0] = 't';

    const g2 = try interner.intern_s("hello");
    try t.expectEqual(g2, 0);

    const g3 = try interner.intern_s("hola");
    try t.expectEqual(g3, 1);
}
