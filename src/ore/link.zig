//! Assemble + link pipeline for `ore run` / `ore build --emit-bin`.
//!
//! The Tungsten backend emits NASM x86-64 assembly (Windows ABI), so ore
//! shells out to `nasm` to produce object files and to `zig cc` to link them
//! into an executable. `malloc` and friends resolve against the C runtime
//! pulled in by `zig cc`.
//!
//! Entry shim: the backend names the entry function `_main` (a NASM-era
//! convention), while the Windows x64 CRT resolves `main` / `WinMain` /
//! `wWinMain` depending on the subsystem it picks. ore therefore links a tiny
//! assembly shim exporting all three entry points, each branching to `_main`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const LinkError = error{
    /// `nasm` or `zig` not found on PATH, or a tool could not be started.
    ToolMissing,
    /// A tool ran but exited nonzero.
    ToolFailed,
    /// Could not write the entry shim.
    WriteFailed,
};

const shim_asm_text =
    \\; ore entry shim
    \\; Tungsten emits `_main`; the Windows x64 CRT needs main/WinMain/wWinMain.
    \\bits 64
    \\default rel
    \\extern _main
    \\global main
    \\global WinMain
    \\global wWinMain
    \\section .text
    \\main:
    \\    jmp _main
    \\WinMain:
    \\    jmp _main
    \\wWinMain:
    \\    jmp _main
    \\
;

/// Run a tool and print its stderr on failure.
fn runTool(io: std.Io, gpa: Allocator, argv: []const []const u8) LinkError!void {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return error.ToolMissing;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("{s}", .{result.stderr});
                return error.ToolFailed;
            }
        },
        else => return error.ToolFailed,
    }
}

/// Assemble `<asm_path>` + entry shim with `nasm -f win64` and link with
/// `zig cc` into `<exe_path>`. Intermediates are removed on success.
pub fn assembleAndLink(io: std.Io, gpa: Allocator, asm_path: []const u8, obj_path: []const u8, exe_path: []const u8) LinkError!void {
    const shim_asm_path = replaceExt(gpa, obj_path, "ore-shim.asm") catch return error.WriteFailed;
    const shim_obj_path = replaceExt(gpa, obj_path, "ore-shim.obj") catch return error.WriteFailed;

    writeShim(io, shim_asm_path) catch return error.WriteFailed;
    defer deleteFile(io, shim_asm_path);
    defer deleteFile(io, shim_obj_path);

    try runTool(io, gpa, &.{ "nasm", "-f", "win64", "-o", shim_obj_path, shim_asm_path });
    try runTool(io, gpa, &.{ "nasm", "-f", "win64", "-o", obj_path, asm_path });
    try runTool(io, gpa, &.{ "zig", "cc", obj_path, shim_obj_path, "-o", exe_path });

    // `zig cc` emits a PDB next to the exe in debug mode; drop it.
    deleteFile(io, replaceExt(gpa, exe_path, "pdb") catch return error.WriteFailed);
}

fn writeShim(io: std.Io, path: []const u8) !void {
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(f, io, &buf);
    try w.interface.writeAll(shim_asm_text);
    try w.interface.flush();
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

/// Remove a file, ignoring whether it exists.
pub fn deleteFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}