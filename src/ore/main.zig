//! ore — the Wolframite package manager.
//!
//! Currently a single-file build tool wrapping the full compiler pipeline
//! (see `compile.zig`), with package scaffolding (`init`) and a run mode that
//! assembles + links via `nasm` and `zig cc` (`run`, `build --emit-bin`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const manifest_mod = @import("manifest.zig");
const compile_mod = @import("compile.zig");
const link_mod = @import("link.zig");
const diag_mod = @import("compiler").diagnostics;

const version_string = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 2) {
        printHelp(io);
        return;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        printHelp(io);
        return;
    }
    if (std.mem.eql(u8, command, "-V") or std.mem.eql(u8, command, "--version")) {
        printOut(io, "ore {s}\n", .{version_string});
        return;
    }

    const code = runCommand(gpa, io, command, args[2..]) catch |err| blk: {
        reportErr(io, "error: {s}\n", .{@errorName(err)});
        break :blk 1;
    };
    std.process.exit(code);
}

fn runCommand(gpa: Allocator, io: Io, command: []const u8, rest: []const []const u8) !u8 {
    if (std.mem.eql(u8, command, "init")) return cmdInit(gpa, io, rest);
    if (std.mem.eql(u8, command, "build")) return cmdBuild(gpa, io, rest);
    if (std.mem.eql(u8, command, "run")) return cmdRun(gpa, io, rest);

    reportErr(io, "error: unknown command '{s}'\n", .{command});
    printHelp(io);
    return 2;
}

// ============================================================================
// init
// ============================================================================

fn cmdInit(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    if (args.len > 1) {
        reportErr(io, "usage: ore init [name]\n", .{});
        return 2;
    }

    if (std.Io.Dir.cwd().access(io, "ore.toml", .{})) |_| {
        reportErr(io, "error: ore.toml already exists in this directory\n", .{});
        return 1;
    } else |_| {}

    const name = if (args.len == 1) blk: {
        break :blk args[0];
    } else blk: {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPath(io, &cwd_buf);
        const cwd = cwd_buf[0..n];
        break :blk std.fs.path.basename(cwd);
    };

    var manifest = manifest_mod.Manifest{ .name = name };
    const manifest_text = try manifest.render(gpa);

    const manifest_file = std.Io.Dir.cwd().createFile(io, "ore.toml", .{}) catch |err| {
        reportErr(io, "error: could not write ore.toml: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer manifest_file.close(io);
    writeFile(io, manifest_file, manifest_text) catch {
        reportErr(io, "error: could not write ore.toml\n", .{});
        return 1;
    };

    std.Io.Dir.cwd().createDirPath(io, "src") catch {};
    const main_file = std.Io.Dir.cwd().createFile(io, "src/main.wfr", .{}) catch |err| {
        reportErr(io, "error: could not write src/main.wfr: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer main_file.close(io);
    writeFile(io, main_file,
        \\fn main() -> i32 {
        \\    return 42
        \\}
        \\
    ) catch {
        reportErr(io, "error: could not write src/main.wfr\n", .{});
        return 1;
    };

    printOut(io, "initialized package '{s}' (entry: src/main.wfr)\n", .{name});
    printOut(io, "next: `ore run`\n", .{});
    return 0;
}

// ============================================================================
// build
// ============================================================================

fn cmdBuild(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var mode: compile_mod.EmitMode = .@"asm";
    var emit_bin = false;
    var file: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printBuildHelp(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return flagNeedsValue(io, arg);
            i += 1;
            out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--ir")) {
            mode = .ir;
        } else if (std.mem.eql(u8, arg, "--emit-bin")) {
            emit_bin = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            reportErr(io, "error: unknown option '{s}'\n", .{arg});
            return 2;
        } else if (file == null) {
            file = arg;
        } else {
            reportErr(io, "error: unexpected argument '{s}'\n", .{arg});
            return 2;
        }
    }

    if (mode == .ir and emit_bin) {
        reportErr(io, "error: --emit-bin cannot be combined with --ir\n", .{});
        return 2;
    }

    const source_path = (try resolveSource(gpa, io, file)) orelse return 2;
    const source = readSource(gpa, io, source_path) orelse return 1;

    const result = compile_mod.compile(gpa, source, mode) catch |err| {
        reportErr(io, "error: {s}\n", .{@errorName(err)});
        return 1;
    };
    reportDiagnostics(io, source_path, &result.diagnostics);

    if (!result.ok) {
        reportErr(io, "error: compilation failed\n", .{});
        return 1;
    }

    switch (mode) {
        .none => unreachable,
        .@"asm" => {
            const asm_path = out_path orelse try replaceExt(gpa, source_path, "asm");
            if ((try writeTextFile(io, asm_path, result.text.?)) != 0) return 1;
            printOut(io, "wrote {s}\n", .{asm_path});
            if (emit_bin) return linkBinary(gpa, io, asm_path);
            return 0;
        },
        .ir => {
            const ir_path = out_path orelse try replaceExt(gpa, source_path, "ir");
            if ((try writeTextFile(io, ir_path, result.text.?)) != 0) return 1;
            printOut(io, "wrote {s}\n", .{ir_path});
            return 0;
        },
    }
}

/// Assemble `<asm_path>` into an executable next to it, cleaning up the
/// intermediates on success.
fn linkBinary(gpa: Allocator, io: Io, asm_path: []const u8) !u8 {
    const obj_path = try replaceExt(gpa, asm_path, "obj");
    const exe_path = try replaceExt(gpa, asm_path, "exe");

    link_mod.assembleAndLink(io, gpa, asm_path, obj_path, exe_path) catch |err| switch (err) {
        error.ToolMissing => {
            reportErr(io, "error: could not run 'nasm' or 'zig' — make sure both are on PATH\n", .{});
            return 1;
        },
        error.ToolFailed => {
            reportErr(io, "error: assemble/link failed (kept {s} and {s} for debugging)\n", .{ asm_path, obj_path });
            return 1;
        },
        error.WriteFailed => {
            reportErr(io, "error: could not write the link shim\n", .{});
            return 1;
        },
    };

    link_mod.deleteFile(io, asm_path);
    link_mod.deleteFile(io, obj_path);
    printOut(io, "wrote {s}\n", .{exe_path});
    return 0;
}

// ============================================================================
// run
// ============================================================================

fn cmdRun(gpa: Allocator, io: Io, args: []const []const u8) !u8 {
    var out_path: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var prog_args: std.ArrayList([]const u8) = .empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printRunHelp(io);
            return 0;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            if (i + 1 >= args.len) return flagNeedsValue(io, arg);
            i += 1;
            out_path = args[i];
        } else if (arg.len > 0 and arg[0] == '-' and file == null) {
            reportErr(io, "error: unknown option '{s}'\n", .{arg});
            return 2;
        } else if (file == null) {
            file = arg;
        } else {
            try prog_args.append(gpa, arg);
        }
    }

    const source_path = (try resolveSource(gpa, io, file)) orelse return 2;
    const source = readSource(gpa, io, source_path) orelse return 1;

    const result = compile_mod.compile(gpa, source, .@"asm") catch |err| {
        reportErr(io, "error: {s}\n", .{@errorName(err)});
        return 1;
    };
    reportDiagnostics(io, source_path, &result.diagnostics);

    if (!result.ok) {
        reportErr(io, "error: compilation failed\n", .{});
        return 1;
    }

    const asm_path = out_path orelse try replaceExt(gpa, source_path, "asm");
    if ((try writeTextFile(io, asm_path, result.text.?)) != 0) return 1;

    const obj_path = try replaceExt(gpa, asm_path, "obj");
    const exe_path = try replaceExt(gpa, asm_path, "exe");
    link_mod.assembleAndLink(io, gpa, asm_path, obj_path, exe_path) catch |err| switch (err) {
        error.ToolMissing => {
            reportErr(io, "error: could not run 'nasm' or 'zig' — make sure both are on PATH\n", .{});
            return 1;
        },
        error.ToolFailed => {
            reportErr(io, "error: assemble/link failed (kept {s} and {s} for debugging)\n", .{ asm_path, obj_path });
            return 1;
        },
        error.WriteFailed => {
            reportErr(io, "error: could not write the link shim\n", .{});
            return 1;
        },
    };
    link_mod.deleteFile(io, asm_path);
    link_mod.deleteFile(io, obj_path);

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(gpa, exe_path);
    try argv.appendSlice(gpa, prog_args.items);
    const argv_slice = try argv.toOwnedSlice(gpa);

    var child = std.process.spawn(io, .{
        .argv = argv_slice,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        reportErr(io, "error: could not start '{s}': {s}\n", .{ exe_path, @errorName(err) });
        return 1;
    };
    const term = child.wait(io) catch |err| {
        reportErr(io, "error: could not wait for '{s}': {s}\n", .{ exe_path, @errorName(err) });
        return 1;
    };

    switch (term) {
        .exited => |code| return code,
        else => {
            reportErr(io, "error: program terminated abnormally\n", .{});
            return 1;
        },
    }
}

// ============================================================================
// Shared helpers
// ============================================================================

/// Resolve the source file to compile: an explicit path, else the `entry`
/// from `ore.toml`. Returns `null` (after reporting) when neither exists.
fn resolveSource(gpa: Allocator, io: Io, file: ?[]const u8) !?[]const u8 {
    if (file) |f| return f;

    const manifest_text = std.Io.Dir.cwd().readFileAlloc(io, "ore.toml", gpa, .unlimited) catch {
        reportErr(io, "error: no input file given and no ore.toml found\n", .{});
        reportErr(io, "hint: run `ore init`, or pass a file: `ore build <file.wfr>`\n", .{});
        return null;
    };
    const manifest = try manifest_mod.Manifest.parse(gpa, manifest_text);
    return manifest.entry;
}

fn readSource(gpa: Allocator, io: Io, path: []const u8) ?[]const u8 {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |err| {
        reportErr(io, "error: could not read '{s}': {s}\n", .{ path, @errorName(err) });
        return null;
    };
    return source;
}

/// Write `text` through a buffered writer into `file` (and flush).
fn writeFile(io: Io, file: std.Io.File, text: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(file, io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn writeTextFile(io: Io, path: []const u8, text: []const u8) !u8 {
    const f = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    defer f.close(io);
    writeFile(io, f, text) catch |err| {
        reportErr(io, "error: could not write '{s}': {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    return 0;
}

/// Replace the extension of `path` with `.new_ext` (allocated).
fn replaceExt(gpa: Allocator, path: []const u8, new_ext: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(path) orelse "";
    const stem = std.fs.path.stem(path);
    if (dir.len == 0) {
        return std.fmt.allocPrint(gpa, "{s}.{s}", .{ stem, new_ext });
    }
    return std.fmt.allocPrint(gpa, "{s}{c}{s}.{s}", .{ dir, std.fs.path.sep, stem, new_ext });
}

fn reportDiagnostics(io: Io, path: []const u8, diagnostics: *const diag_mod.Diagnostics) void {
    for (diagnostics.items.items) |item| {
        var buf: [4096]u8 = undefined;
        var w: Io.File.Writer = .init(.stderr(), io, &buf);
        if (item.location) |loc| {
            w.interface.print("{s}:{d}:{d}: {s} [{s}]: {s}\n", .{
                path,           loc.line,
                loc.column,     @tagName(item.severity),
                @tagName(item.phase),
                item.message,
            }) catch {};
        } else {
            w.interface.print("{s}: {s} [{s}]: {s}\n", .{
                path,
                @tagName(item.severity),
                @tagName(item.phase),
                item.message,
            }) catch {};
        }
        w.interface.flush() catch {};
    }
}

fn flagNeedsValue(io: Io, flag: []const u8) u8 {
    reportErr(io, "error: option '{s}' requires a value\n", .{flag});
    return 2;
}

fn printOut(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn reportErr(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn printHelp(io: Io) void {
    printOut(io,
        \\ore {s} — the Wolframite package manager
        \\
        \\Compiles and runs single Wolframite source files today; dependency
        \\management is on the roadmap.
        \\
        \\Usage:
        \\  ore <command> [options]
        \\
        \\Commands:
        \\  init [name]      Scaffold a new package (ore.toml + src/main.wfr)
        \\  build [file]     Compile a .wfr file (or the package entry) to NASM assembly
        \\  run [file]       Compile, assemble, link (nasm + zig cc), and execute
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -V, --version    Show version information
        \\
        \\Run `ore <command> --help` for command-specific options.
        \\
    , .{version_string});
}

fn printBuildHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore build [options] [file]
        \\
        \\Compile a single Wolframite source file to NASM x86-64 assembly.
        \\When no file is given, the entry from ore.toml is used.
        \\
        \\Options:
        \\  -o, --output <path>  Write output to <path> (default: <input>.asm)
        \\      --ir             Emit textual Tungsten IR instead of assembly
        \\      --emit-bin       Also assemble and link into an executable (needs nasm)
        \\  -h, --help           Show this help
        \\
        \\Exit codes:
        \\  0  success
        \\  1  compilation or I/O failure
        \\  2  usage error
        \\
    , .{});
}

fn printRunHelp(io: Io) void {
    printOut(io,
        \\Usage:
        \\  ore run [options] [file] [args...]
        \\
        \\Compile, assemble, link (nasm + zig cc), and execute a program.
        \\When no file is given, the entry from ore.toml is used. Arguments
        \\after the file are passed to the program.
        \\
        \\Options:
        \\  -o, --output <path>  Assembly output path (default: <input>.asm)
        \\  -h, --help           Show this help
        \\
    , .{});
}
