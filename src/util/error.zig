const std = @import("std");

pub const Error = struct {
    message: []const u8,
    line: ?usize = null,
    column: ?usize = null,

    pub fn format(self: Error, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        if (self.line) |line| {
            try writer.print("line {d}", .{line});
            if (self.column) |col| {
                try writer.print(":{d}", .{col});
            }
            try writer.print(": {s}\n", .{self.message});
        } else {
            try writer.print("{s}\n", .{self.message});
        }
    }
};

pub const ErrorList = struct {
    allocator: std.mem.Allocator,
    errors: std.array_list.Managed(Error),

    pub fn init(allocator: std.mem.Allocator) ErrorList {
        return .{
            .allocator = allocator,
            .errors = std.array_list.Managed(Error).init(allocator),
        };
    }

    pub fn deinit(self: *ErrorList) void {
        self.errors.deinit();
    }

    pub fn add(self: *ErrorList, message: []const u8, line: ?usize, column: ?usize) !void {
        try self.errors.append(.{
            .message = message,
            .line = line,
            .column = column,
        });
    }

    pub fn hasErrors(self: ErrorList) bool {
        return self.errors.items.len > 0;
    }

    pub fn count(self: ErrorList) usize {
        return self.errors.items.len;
    }

    pub fn printAll(self: ErrorList, writer: anytype) !void {
        for (self.errors.items) |err| {
            try writer.print("error: ", .{});
            try err.format("", .{}, writer);
        }
    }
};
