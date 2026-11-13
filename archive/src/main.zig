const std = @import("std");
const build_opts = @import("build_opts");
const Io = std.Io;

const fino = @import("fino");

const Mode = enum {
    normal,
    lexer,
    bench,
    astsize,
    parser_flat,
    parser_tree,
    compiler,

    fn prompt(self: Mode) []const u8 {
        return switch (self) {
            .normal => "fino",
            .bench => "benchmark",
            .astsize => "astsize",
            .lexer => "lex",
            .parser_flat => "ast",
            .parser_tree => "tree",
            .compiler => "compiler",
        };
    }

    fn label(self: Mode) []const u8 {
        return switch (self) {
            .normal => "normal",
            .lexer => "lexer",
            .bench => "bench",
            .astsize => "astsize",
            .parser_flat => "parser (flat)",
            .parser_tree => "parser (tree)",
            .compiler => "compiler",
        };
    }
};

const command_modes: std.StaticStringMap(Mode) = .initComptime(.{
    .{ "/l", .lexer },
    .{ "/p", .parser_flat },
    .{ "/pp", .parser_tree },
    .{ "/k", .normal },
});

const command_strings: std.StaticStringMap(Mode) = .initComptime(.{
    .{ "lexer", .lexer },
    .{ "bench", .bench },
    .{ "astsize", .astsize },
    .{ "parser_tree", .parser_tree },
    .{ "parser_flat", .parser_flat },
    .{ "compiler", .compiler },
    .{ "normal", .normal },
});

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {
        unreachable;
    };

    // var custom_gpa = std.heap.DebugAllocator(.{ .stack_trace_frames = 25 }){};
    // defer std.debug.assert(custom_gpa.deinit() == .ok);

    if (args.len >= 2) {
        const mode = parseMode(args[2..]);
        std.debug.print("mode: {t} - {t}\n", .{ mode, build_opts.kind });
        try runFile(out, io, init.gpa, args[1], mode);
        return;
    }

    try runRepl(out, io, init.gpa);
}

fn parseMode(args: []const [:0]const u8) Mode {
    if (args.len == 0) return .normal;

    const mode_s = std.mem.trimStart(u8, args[0], "-");
    return command_strings.get(mode_s) orelse .normal;
}
fn runFile(out: *Io.Writer, io: Io, gpa: std.mem.Allocator, file_path: []const u8, mode: Mode) !void {
    const src = Io.Dir.readFileAllocOptions(.cwd(), io, file_path, gpa, .unlimited, .of(u8), 0) catch |err| {
        std.debug.print("Failed to read '{s}': {}\n", .{ file_path, err });
        return err;
    };
    defer gpa.free(src);

    var prog: fino.Program = try .init(gpa);
    defer prog.deinit();
    var vm: fino.Vm = .init(out, gpa, &prog.interner);
    defer vm.deinit();

    try runSrc(&prog, &vm, gpa, src, mode);
}

fn runSrc(prog: *fino.Program, vm: *fino.Vm, gpa: std.mem.Allocator, src: [:0]const u8, mode: Mode) !void {
    const out = vm.out;
    switch (mode) {
        .normal => {
            prog.run(vm, src) catch |e| {
                try out.print("error: {t}\n", .{e});
            };
        },
        .lexer => try fino.display.printTokens(out, src),
        .bench => try prog.benchParser(src),
        .astsize => try fino.display.printAstSize(out, gpa, src),
        .parser_flat => try fino.display.printAstFlat(out, gpa, src),
        .parser_tree => try fino.display.printAstTree(out, gpa, src),
        .compiler => try prog.printInsts(out, src),
    }
}

fn runRepl(out: *Io.Writer, io: Io, gpa: std.mem.Allocator) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = Io.File.stdin().reader(io, &stdin_buf);
    const in = &stdin_r.interface;

    var mode: Mode = .normal;

    try out.print("fino repl. type /h for help.\n", .{});
    try out.flush();

    // session state: the growing compiled image plus the vm globals
    var prog: fino.Program = try .init(gpa);
    defer prog.deinit();
    var vm: fino.Vm = .init(out, gpa, &prog.interner);
    defer vm.deinit();

    while (true) {
        try out.print("{s}> ", .{mode.prompt()});
        try out.flush();

        const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try out.print("\n", .{});
                try out.flush();
                return;
            },
            else => return err,
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '/') {
            try handleCommand(out, trimmed, &mode);
            try out.flush();
            continue;
        }

        // trimmed lives inside stdin_buf; the byte right after it is still
        // in-buffer (one of the trimmed trailing chars), safe to overwrite
        // with the 0 sentinel without allocating.
        const mut_ptr: [*]u8 = @constCast(trimmed.ptr);
        mut_ptr[trimmed.len] = 0;
        const src: [:0]const u8 = mut_ptr[0..trimmed.len :0];

        try runSrc(&prog, &vm, gpa, src, mode);

        try out.flush();
    }
}

fn handleCommand(out: *Io.Writer, cmd: []const u8, mode: *Mode) !void {
    if (std.mem.eql(u8, cmd, "/h")) {
        return printHelp(out);
    }
    if (command_modes.get(cmd)) |new_mode| {
        mode.* = new_mode;
        try out.print("[mode: {s}]\n", .{new_mode.label()});
        return;
    }
    try out.print("unknown command: {s} (try /h)\n", .{cmd});
}

fn printHelp(out: *Io.Writer) !void {
    try out.print(
        \\fino repl commands:
        \\  /b   bench mode  - runs the lexer and parser, no printing
        \\  /l   lexer mode  - print the lexer output only
        \\  /p   parser mode - print the flat ast only
        \\  /pp  parser mode - print the ast in tree form
        \\  /k   clear mode  - return to normal mode
        \\  /h   help        - print this message
        \\
    , .{});
}
