//! Ztype 行法分析器
//! 把源码切成"逻辑行"：去注释、去空行、保留缩进，供语法解析器分类。
//! Ztype 的语法以行为单位（标题、列表、表格、语义块都以行首标记开始），
//! 因此行法分析器比字符级 Token 流更贴合语言本身。

const std = @import("std");

pub const Line = struct {
    /// 1 起始的行号
    number: usize,
    /// 去掉注释后的内容
    text: []const u8,
    /// 行首缩进（空格数）
    indent: usize,
    /// 是否为空行（逻辑分段）
    blank: bool,
};

pub const Lexer = struct {
    allocator: std.mem.Allocator,
    lines: []Line,
    index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) !Lexer {
        return .{
            .allocator = allocator,
            .lines = try splitLines(allocator, source),
        };
    }

    pub fn reset(self: *Lexer) void {
        self.index = 0;
    }

    pub fn next(self: *Lexer) ?Line {
        if (self.index >= self.lines.len) return null;
        const line = self.lines[self.index];
        self.index += 1;
        return line;
    }

    pub fn peek(self: *Lexer) ?Line {
        if (self.index >= self.lines.len) return null;
        return self.lines[self.index];
    }

    pub fn done(self: *const Lexer) bool {
        return self.index >= self.lines.len;
    }

    /// 读取到下一个空行之前的所有行（用于语义块、段落）
    pub fn collectUntilBlank(self: *Lexer) ![]Line {
        var out = std.array_list.Managed(Line).init(self.allocator);
        while (self.next()) |line| {
            if (line.blank) break;
            try out.append(line);
        }
        return out.toOwnedSlice();
    }
};

fn splitLines(allocator: std.mem.Allocator, source: []const u8) ![]Line {
    var out = std.array_list.Managed(Line).init(allocator);

    // 先剥离 ;{ ... } 块注释
    const cleaned = try stripBlockComments(allocator, source);

    var number: usize = 1;
    var rest = cleaned;
    while (true) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const raw = if (nl) |i| rest[0..i] else rest;
        const text = stripLineComment(raw);
        const indent = countIndent(raw);
        try out.append(.{
            .number = number,
            .text = try allocator.dupe(u8, text),
            .indent = indent,
            .blank = text.len == 0,
        });
        if (nl == null) break;
        rest = rest[nl.? + 1 ..];
        number += 1;
    }
    return out.toOwnedSlice();
}

fn stripBlockComments(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == ';' and i + 1 < source.len and source[i + 1] == '{') {
            var depth: usize = 1;
            i += 2;
            while (i < source.len and depth > 0) {
                if (source[i] == '{') depth += 1 else if (source[i] == '}') depth -= 1;
                i += 1;
            }
            continue;
        }
        try out.append(source[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

/// 行首的 `;` 视为注释；行中的 `;` 只有紧跟空白时才视为注释
fn countIndent(raw: []const u8) usize {
    var n: usize = 0;
    for (raw) |c| {
        if (c == ' ') n += 1 else if (c == '\t') n += 4 else break;
    }
    return n;
}


fn stripLineComment(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0) return trimmed;
    if (trimmed[0] == ';') return "";
    var i: usize = 0;
    while (i < trimmed.len) {
        if (trimmed[i] == ';' and (i == 0 or std.ascii.isWhitespace(trimmed[i - 1]))) {
            return std.mem.trim(u8, trimmed[0..i], " \t\r");
        }
        i += 1;
    }
    return trimmed;
}
