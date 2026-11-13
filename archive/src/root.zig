const build_opts = @import("build_opts");

pub const Vm = @import("Vm.zig");

// Only post_tree tracks the current Lexer; the other variants are stale
// benchmark experiments.
pub const Program = switch (build_opts.kind) {
    .post_tree => @import("post_tree/Program.zig"),
    else => @compileError("variant '" ++ @tagName(build_opts.kind) ++ "' is stale; only post_tree builds"),
};

pub const display = switch (build_opts.kind) {
    .post_tree => @import("post_tree/display.zig"),
    else => @compileError("variant '" ++ @tagName(build_opts.kind) ++ "' is stale; only post_tree builds"),
};

test {
    _ = Program;
    _ = display;
}
