const std = @import("std");

pub const Severity = enum {
    @"error",
    warning,
    note,
    info,
};

pub const Phase = enum {
    lexer,
    parser,
    semantic,
    codegen,
};

pub const Location = struct {
    line: u32,
    column: u32,
};

pub const Diagnostic = struct {
    severity: Severity,
    phase: Phase,
    message: []const u8,
    location: ?Location,
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Diagnostic),
    owns_messages: bool = false,

    pub fn init(allocator: std.mem.Allocator) Diagnostics {
        return .{
            .allocator = allocator,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Diagnostics) void {
        if (self.owns_messages) {
            for (self.items.items) |item| {
                self.allocator.free(item.message);
            }
        }
        self.items.deinit(self.allocator);
    }

    pub fn add(self: *Diagnostics, severity: Severity, phase: Phase, message: []const u8, location: ?Location) !void {
        try self.items.append(self.allocator, .{
            .severity = severity,
            .phase = phase,
            .message = message,
            .location = location,
        });
    }

    pub fn hasErrors(self: *const Diagnostics) bool {
        for (self.items.items) |item| {
            if (item.severity == .@"error") return true;
        }
        return false;
    }

    pub fn count(self: *const Diagnostics, severity: Severity) usize {
        var result: usize = 0;
        for (self.items.items) |item| {
            if (item.severity == severity) result += 1;
        }
        return result;
    }

    pub fn clear(self: *Diagnostics) void {
        self.items.clearRetainingCapacity();
    }
};

test "diagnostics: add and hasErrors" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    try std.testing.expect(!diags.hasErrors());

    try diags.add(.@"error", .lexer, "unexpected character", .{ .line = 1, .column = 5 });
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), diags.count(.@"error"));

    try diags.add(.warning, .parser, "unused variable", null);
    try std.testing.expectEqual(@as(usize, 1), diags.count(.warning));
}

test "diagnostics: clear" {
    var diags = Diagnostics.init(std.testing.allocator);
    defer diags.deinit();

    try diags.add(.@"error", .lexer, "err1", null);
    try diags.add(.@"error", .parser, "err2", null);
    try std.testing.expect(diags.hasErrors());

    diags.clear();
    try std.testing.expect(!diags.hasErrors());
}
