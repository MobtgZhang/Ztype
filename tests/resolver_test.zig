//! 变量解析器单元测试

const std = @import("std");
const Resolver = @import("../src/resolver.zig").Resolver;

test "resolver: let 变量" {
    const allocator = std.testing.allocator;
    var r = Resolver.init(allocator);
    defer r.deinit();

    try r.evalScript("let version = \"1.0.0\"");
    const val = try r.evalExpr("version");
    try std.testing.expect(val != null);
    try std.testing.expect(std.mem.eql(u8, val.?, "1.0.0"));
}

test "resolver: 未知变量" {
    const allocator = std.testing.allocator;
    var r = Resolver.init(allocator);
    defer r.deinit();

    const val = r.evalExpr("unknown") catch null;
    try std.testing.expect(val == null);
}
