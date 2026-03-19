const std = @import("std");

/// 简单 arena 分配器封装，用于 AST 等短生命周期数据
pub const Arena = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator) Arena {
        return .{
            .allocator = allocator,
            .buffers = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Arena) void {
        for (self.buffers.items) |buf| {
            self.allocator.free(buf);
        }
        self.buffers.deinit();
    }

    pub fn dupe(self: *Arena, bytes: []const u8) ![]const u8 {
        const copy = try self.allocator.dupe(u8, bytes);
        try self.buffers.append(copy);
        return copy;
    }

    pub fn dupeZ(self: *Arena, bytes: []const u8) ![:0]const u8 {
        const copy = try self.allocator.dupeZ(u8, bytes);
        try self.buffers.append(copy);
        return copy;
    }
};
