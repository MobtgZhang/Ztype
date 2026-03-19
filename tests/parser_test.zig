//! 语法解析器单元测试

const std = @import("std");
const Parser = @import("../src/parser.zig").Parser;

test "parser: 元数据解析" {
    const allocator = std.testing.allocator;
    const source =
        \\---
        \\title: 测试文档
        \\author: 作者
        \\---
    ;
    var parser = Parser.init(allocator, source);
    var doc = parser.parse() catch return;
    defer doc.deinit();

    try std.testing.expect(doc.metadata != null);
    const meta = doc.metadata.?;
    try std.testing.expect(meta.get("title").? != null);
    try std.testing.expect(std.mem.eql(u8, meta.get("title").?, "测试文档"));
}

test "parser: 标题与段落" {
    const allocator = std.testing.allocator;
    const source =
        \\= 第一章
        \\
        \\这是段落内容。
    ;
    var parser = Parser.init(allocator, source);
    var doc = parser.parse() catch return;
    defer doc.deinit();

    try std.testing.expect(doc.content.items.len >= 1);
}
