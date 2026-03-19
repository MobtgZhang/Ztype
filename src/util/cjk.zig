//! CJK (中日韩) 字符编码支持
//! 提供 UTF-8 到 PDF/RTF 等格式的 Unicode 编码转换

const std = @import("std");

/// 将 UTF-8 字符串编码为 RTF 格式，支持 CJK
/// RTF 使用 \uN? 表示 Unicode 码点，? 是旧版阅读器的替换字符
pub fn utf8ToRtf(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var utf8_view = std.unicode.Utf8View.init(s) catch {
        // 无效 UTF-8，按 ASCII 转义
        return escapeRtfAscii(allocator, s);
    };
    var iter = utf8_view.iterator();

    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint < 128) {
            // ASCII 特殊字符转义
            switch (codepoint) {
                '\\' => try result.appendSlice("\\\\"),
                '{' => try result.appendSlice("\\{"),
                '}' => try result.appendSlice("\\}"),
                '\n' => try result.appendSlice("\\par\n"),
                '\r' => {},
                '\t' => try result.appendSlice("\\tab "),
                else => try result.append(@as(u8, @intCast(codepoint))),
            }
        } else {
            // Unicode: RTF \uN? 其中 N 为有符号16位 (-32768..32767)
            // codepoint 0..32767 直接使用；32768..65535 用 codepoint-65536
            const n: i16 = if (codepoint <= 32767)
                @as(i16, @intCast(codepoint))
            else if (codepoint <= 0xFFFF)
                @as(i16, @intCast(@as(i32, @intCast(codepoint)) - 65536))
            else
                @as(i16, -3); // U+FFFD for astral plane
            try result.writer().print("\\u{d}?", .{n});
        }
    }
    return result.toOwnedSlice();
}

fn escapeRtfAscii(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    for (s) |c| {
        switch (c) {
            '\\' => try result.appendSlice("\\\\"),
            '{' => try result.appendSlice("\\{"),
            '}' => try result.appendSlice("\\}"),
            '\n' => try result.appendSlice("\\par\n"),
            '\r' => {},
            '\t' => try result.appendSlice("\\tab "),
            else => if (c >= 32 and c < 127) try result.append(c) else try result.append('?'),
        }
    }
    return result.toOwnedSlice();
}

/// 将 UTF-8 字符串编码为 PDF 格式，支持 CJK
/// PDF 使用 <FEFFxxxx> 表示 UTF-16BE 十六进制
pub fn utf8ToPdfHex(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var utf8_view = std.unicode.Utf8View.init(s) catch {
        return escapePdfAscii(allocator, s);
    };
    var iter = utf8_view.iterator();

    try result.appendSlice("<FEFF"); // UTF-16BE BOM
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint < 128) {
            switch (codepoint) {
                '\\' => try result.appendSlice("005C"),
                '(' => try result.appendSlice("0028"),
                ')' => try result.appendSlice("0029"),
                '<' => try result.appendSlice("003C"),
                '>' => try result.appendSlice("003E"),
                '[' => try result.appendSlice("005B"),
                ']' => try result.appendSlice("005D"),
                '{' => try result.appendSlice("007B"),
                '}' => try result.appendSlice("007D"),
                '\n' => try result.appendSlice("000A"),
                '\r' => try result.appendSlice("000D"),
                '\t' => try result.appendSlice("0009"),
                else => try result.writer().print("{X:0>4}", .{codepoint}),
            }
        } else {
            // UTF-16BE 十六进制（BOM 已在开头输出）
            if (codepoint <= 0xFFFF) {
                try result.writer().print("{X:0>4}", .{codepoint});
            } else {
                const high = 0xD800 + ((codepoint - 0x10000) >> 10);
                const low = 0xDC00 + ((codepoint - 0x10000) & 0x3FF);
                try result.writer().print("{X:0>4}{X:0>4}", .{ high, low });
            }
        }
    }
    try result.append('>');
    return result.toOwnedSlice();
}

fn escapePdfAscii(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    try result.append('(');
    for (s) |c| {
        switch (c) {
            '\\' => try result.appendSlice("\\\\"),
            '(' => try result.appendSlice("\\("),
            ')' => try result.appendSlice("\\)"),
            '\n' => try result.appendSlice("\\n"),
            '\r' => try result.appendSlice("\\r"),
            '\t' => try result.appendSlice("\\t"),
            else => if (c >= 32 and c < 127) try result.append(c) else try result.append('?'),
        }
    }
    try result.append(')');
    return result.toOwnedSlice();
}
