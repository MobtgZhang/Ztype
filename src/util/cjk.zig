//! CJK (中日韩) 字符编码支持
//! 提供 UTF-8 到 PDF/RTF 等格式的 Unicode 编码转换

const std = @import("std");

pub fn hasNonAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 128) return true;
    }
    return false;
}

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

/// Check if a Unicode codepoint is a CJK character (Chinese/Japanese/Korean)
pub fn isCjk(cp: u21) bool {
    return (cp >= 0x4E00 and cp <= 0x9FFF) or // CJK Unified Ideographs
        (cp >= 0x3400 and cp <= 0x4DBF) or // CJK Extension A
        (cp >= 0x20000 and cp <= 0x2A6DF) or // CJK Extension B
        (cp >= 0x2A700 and cp <= 0x2B73F) or // CJK Extension C
        (cp >= 0x2B740 and cp <= 0x2B81F) or // CJK Extension D
        (cp >= 0xF900 and cp <= 0xFAFF) or // CJK Compatibility Ideographs
        (cp >= 0x3000 and cp <= 0x303F) or // CJK Symbols and Punctuation
        (cp >= 0xFF00 and cp <= 0xFFEF) or // Fullwidth Forms
        (cp >= 0x3040 and cp <= 0x309F) or // Hiragana
        (cp >= 0x30A0 and cp <= 0x30FF) or // Katakana
        (cp >= 0xAC00 and cp <= 0xD7AF); // Hangul Syllables
}

/// Estimate the width of a single codepoint in PDF points at a given font size.
/// CJK characters are full-width (1.0 * font_size), Latin characters use
/// approximate Helvetica metrics.
pub fn charWidthPt(cp: u21, font_size: f64) f64 {
    if (isCjk(cp)) return font_size;
    return switch (cp) {
        ' ' => font_size * 0.278,
        'i', 'l', '!' => font_size * 0.278,
        'f', 'j', 'r', 't' => font_size * 0.333,
        'm', 'w' => font_size * 0.778,
        'M', 'W' => font_size * 0.833,
        else => if (cp >= 'A' and cp <= 'Z')
            font_size * 0.667
        else if (cp >= 'a' and cp <= 'z')
            font_size * 0.500
        else if (cp >= '0' and cp <= '9')
            font_size * 0.556
        else
            font_size * 0.500,
    };
}

/// Measure the width of a UTF-8 string in PDF points
pub fn measureTextWidth(s: []const u8, font_size: f64) f64 {
    var width: f64 = 0;
    var view = std.unicode.Utf8View.init(s) catch return @as(f64, @floatFromInt(s.len)) * font_size * 0.5;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        width += charWidthPt(cp, font_size);
    }
    return width;
}

/// A text segment — either Latin (rendered with Helvetica) or CJK (rendered with CIDFont)
pub const TextSegment = struct {
    text: []const u8,
    is_cjk: bool,
};

/// Split a UTF-8 string into alternating Latin/CJK segments for font switching
pub fn splitTextSegments(allocator: std.mem.Allocator, s: []const u8) ![]TextSegment {
    var segments = std.array_list.Managed(TextSegment).init(allocator);
    errdefer {
        for (segments.items) |seg| allocator.free(seg.text);
        segments.deinit();
    }

    var view = std.unicode.Utf8View.init(s) catch {
        try segments.append(.{ .text = try allocator.dupe(u8, s), .is_cjk = false });
        return segments.toOwnedSlice();
    };
    var iter = view.iterator();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    var current_is_cjk = false;
    var first = true;

    const bytes = iter.bytes;
    _ = bytes;
    var prev_i = iter.i;

    while (iter.nextCodepoint()) |cp| {
        const cp_is_cjk = isCjk(cp);
        const cur_i = iter.i;
        const char_bytes = s[prev_i..cur_i];

        if (first) {
            current_is_cjk = cp_is_cjk;
            first = false;
        }

        if (cp_is_cjk != current_is_cjk and buf.items.len > 0) {
            try segments.append(.{
                .text = try allocator.dupe(u8, buf.items),
                .is_cjk = current_is_cjk,
            });
            buf.clearRetainingCapacity();
            current_is_cjk = cp_is_cjk;
        }

        try buf.appendSlice(char_bytes);
        prev_i = cur_i;
    }

    if (buf.items.len > 0) {
        try segments.append(.{
            .text = try allocator.dupe(u8, buf.items),
            .is_cjk = current_is_cjk,
        });
    }

    return segments.toOwnedSlice();
}
