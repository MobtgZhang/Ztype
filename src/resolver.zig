//! Ztype 解析器
//! 变量替换、@() 表达式求值、交叉引用解析

const std = @import("std");
const ast = @import("ast.zig");

pub const Resolver = struct {
    allocator: std.mem.Allocator,
    variables: std.StringHashMap(Value),

    pub const Value = union(enum) {
        string: []const u8,
        number: i64,
        boolean: bool,
        list: std.array_list.Managed([]const u8),
    };

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{
            .allocator = allocator,
            .variables = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Resolver) void {
        var iter = self.variables.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .string => |s| self.allocator.free(s),
                .list => |*l| {
                    for (l.items) |item| self.allocator.free(item);
                    l.deinit();
                },
                else => {},
            }
            self.allocator.free(entry.key_ptr.*);
        }
        self.variables.deinit();
    }

    /// 从脚本块源码中解析并执行变量定义
    pub fn evalScript(self: *Resolver, source: []const u8) !void {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == ';') continue; // 注释

            if (std.mem.startsWith(u8, trimmed, "let ")) {
                const rest = trimmed[4..];
                if (std.mem.indexOf(u8, rest, " = ")) |eq_pos| {
                    const key = std.mem.trim(u8, rest[0..eq_pos], " ");
                    const value_str = std.mem.trim(u8, rest[eq_pos + 3 ..], " \"");
                    const key_dup = try self.allocator.dupe(u8, key);
                    const val_dup = try self.allocator.dupe(u8, value_str);
                    try self.variables.put(key_dup, .{ .string = val_dup });
                }
            }
        }
    }

    /// 求值简单表达式，如变量名、join(authors, "、") 等
    pub fn evalExpr(self: *const Resolver, expr: []const u8) !?[]const u8 {
        const trimmed = std.mem.trim(u8, expr, " \t");
        if (trimmed.len == 0) return null;

        // 直接变量引用
        if (self.variables.get(trimmed)) |v| {
            return switch (v) {
                .string => |s| s,
                .number => |n| blk: {
                    var buf: [32]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch break :blk null;
                    break :blk try self.allocator.dupe(u8, s);
                },
                .boolean => |b| if (b) "true" else "false",
                .list => return null, // 需要 join 等
            };
        }

        // 简单函数调用 join(list, sep)
        if (std.mem.indexOf(u8, trimmed, "join(")) |_| {
            return self.evalJoin(trimmed);
        }

        // today()
        if (std.mem.eql(u8, trimmed, "today()")) {
            return self.evalToday();
        }

        return null;
    }

    fn evalJoin(self: *const Resolver, expr: []const u8) !?[]const u8 {
        const start = std.mem.indexOf(u8, expr, "join(") orelse return null;
        const inner = expr[start + 5 ..];
        const end_paren = std.mem.indexOfScalar(u8, inner, ')') orelse return null;
        const args_str = inner[0..end_paren];
        var iter = std.mem.splitScalar(u8, args_str, ',');
        const list_name = std.mem.trim(u8, iter.next() orelse return null, " ");
        const sep = std.mem.trim(u8, iter.next() orelse return null, " \"");
        const v = self.variables.get(list_name) orelse return null;
        const list = switch (v) {
            .list => |l| l,
            else => return null,
        };
        var out = std.array_list.Managed(u8).init(self.allocator);
        for (list.items, 0..) |item, i| {
            if (i > 0) try out.appendSlice(sep);
            try out.appendSlice(item);
        }
        return try out.toOwnedSlice();
    }

    fn evalToday(self: *const Resolver) !?[]const u8 {
        const timestamp = std.time.timestamp();
        const epoch_day: i64 = @intCast(@divFloor(timestamp, 86400));
        const day = @rem(epoch_day, 31) + 1;
        const month = @rem(@divFloor(epoch_day, 31), 12) + 1;
        const year = @divFloor(epoch_day, 31 * 12) + 1970;
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}-{:0>2}-{:0>2}", .{ year, month, day }) catch return null;
        return try self.allocator.dupe(u8, s);
    }
};
