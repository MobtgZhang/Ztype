//! 词法分析器单元测试

const std = @import("std");
const Lexer = @import("../src/lexer.zig").Lexer;
const ast = @import("../src/ast.zig");

test "lexer: 元数据分隔符" {
    const allocator = std.testing.allocator;
    const source = "---\ntitle: Hello\n---";
    var lexer = Lexer.init(allocator, source);
    const t1 = (try lexer.next()).?;
    try std.testing.expect(t1.type == .meta_start);
    _ = try lexer.next(); // newline
    const t3 = (try lexer.next()).?;
    try std.testing.expect(t3.type == .identifier);
    const t4 = (try lexer.next()).?;
    try std.testing.expect(t4.type == .colon);
}

test "lexer: 标题 token" {
    const allocator = std.testing.allocator;
    const source = "== 第二节";
    var lexer = Lexer.init(allocator, source);
    const t = (try lexer.next()).?;
    try std.testing.expect(t.type == .heading);
    try std.testing.expect(t.extra == .{ .heading_level = 2 });
}

test "lexer: 脚本块开始" {
    const allocator = std.testing.allocator;
    const source = "@{\n  let x = 1\n}";
    var lexer = Lexer.init(allocator, source);
    const t = (try lexer.next()).?;
    try std.testing.expect(t.type == .script_start);
}
