const build_opts = @import("build_opts");

pub const Engine = switch (build_opts.kind) {
    .moar_smaller => @import("moar_smaller/Engine.zig"),
    .post_tree => @import("post_tree/Engine.zig"),
    .forest_pointer => @import("forest_pointer/Engine.zig"),
    .index_sea => @import("index_sea/Engine.zig"),
};

test {
    _ = Engine;
}
