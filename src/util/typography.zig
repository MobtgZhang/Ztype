//! 智能排版（smart typography）
//! 参考 Typst：把 ASCII 输入转换为排版正确的字符。
//!   "..."        -> 弯引号 U+201C / U+201D
//!   '...' / don't -> 弯撇号 U+2018 / U+2019
//!   --           -> en dash U+2013
//!   ---          -> em dash U+2014
//!   ...          -> 省略号 U+2026
//!   (c) (r) (tm) (p) -> 版权/注册/商标/录音符号
//!   +- /- *-     -> 正负号、除号、乘号
//!   ->           -> 箭头
//!
//! 引号方向取决于前一个可见字符，因此需要一个跨行内片段保持的状态。

const std = @import("std");

pub const Options = struct {
    quotes: bool = true,
    dashes: bool = true,
    ellipsis: bool = true,
    symbols: bool = true,
    /// TeX 的 spacefactor：句末标点后空格更宽
    spacefactor: bool = true,
};

pub const defaults = Options{};

/// 跨行内片段保持的上下文状态
pub const State = struct {
    /// 上一个可见字符的码点
    prev: ?u21 = null,
};

/// 判断引号是开引号还是闭引号
pub fn isOpenQuote(prev: ?u21) bool {
    const p = prev orelse return true;
    if (p <= 0x20) return true;
    switch (p) {
        '(', '[', '{', '“', '‘', '–', '—', '-', '/', '\\', '>', '=' => return true,
        else => return false,
    }
}

/// 该标点之后是否应加宽空格（TeX 的 sentence space）
pub fn isSentenceEnding(cp: u21) bool {
    return switch (cp) {
        '.', '!', '?', ':', ';', 0x2026, 0x201D, 0x2019 => true,
        else => false,
    };
}

fn writeCodepoint(out: *std.array_list.Managed(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.append('?');
        return;
    };
    try out.appendSlice(buf[0..n]);
}

/// 对一段纯文本做替换，并把结果写入 out
pub fn append(out: *std.array_list.Managed(u8), text: []const u8, opts: Options, state: *State) !void {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        if (opts.quotes and (c == '"' or c == '\'')) {
            const open = isOpenQuote(state.prev);
            const cp: u21 = if (c == '"') (if (open) 0x201C else 0x201D) else (if (open) 0x2018 else 0x2019);
            try writeCodepoint(out, cp);
            state.prev = cp;
            i += 1;
            continue;
        }

        if (opts.ellipsis and c == '.' and i + 2 < text.len and text[i + 1] == '.' and text[i + 2] == '.') {
            try writeCodepoint(out, 0x2026);
            state.prev = 0x2026;
            i += 3;
            continue;
        }

        if (opts.dashes and c == '-') {
            var count: usize = 0;
            while (i + count < text.len and text[i + count] == '-') count += 1;
            if (count >= 3) {
                try writeCodepoint(out, 0x2014);
                state.prev = 0x2014;
                i += count;
                continue;
            }
            if (count == 2) {
                try writeCodepoint(out, 0x2013);
                state.prev = 0x2013;
                i += count;
                continue;
            }
        }

        if (opts.symbols) {
            if (c == '(' and i + 1 < text.len) {
                const n = text[i + 1];
                const close = i + 2 < text.len and text[i + 2] == ')';
                if (close) {
                    const cp: ?u21 = switch (n) {
                        'c' => 0x00A9,
                        'r' => 0x00AE,
                        'p' => 0x2117,
                        else => null,
                    };
                    if (cp) |v| {
                        try writeCodepoint(out, v);
                        state.prev = v;
                        i += 3;
                        continue;
                    }
                }
                if (n == 't' and i + 3 < text.len and text[i + 2] == 'm' and text[i + 3] == ')') {
                    try writeCodepoint(out, 0x2122);
                    state.prev = 0x2122;
                    i += 4;
                    continue;
                }
            }
            if (c == '+' and i + 1 < text.len and text[i + 1] == '-') {
                try writeCodepoint(out, 0x00B1);
                state.prev = 0x00B1;
                i += 2;
                continue;
            }
            if (c == '/' and i + 1 < text.len and text[i + 1] == '-') {
                try writeCodepoint(out, 0x00F7);
                state.prev = 0x00F7;
                i += 2;
                continue;
            }
            if (c == '*' and i + 1 < text.len and text[i + 1] == '-') {
                try writeCodepoint(out, 0x00D7);
                state.prev = 0x00D7;
                i += 2;
                continue;
            }
            if (c == '-' and i + 1 < text.len and text[i + 1] == '>') {
                try writeCodepoint(out, 0x2192);
                state.prev = 0x2192;
                i += 2;
                continue;
            }
        }

        try out.append(c);
        state.prev = @as(u21, @intCast(c));
        i += 1;
    }
}

pub fn substitute(allocator: std.mem.Allocator, text: []const u8, opts: Options, state: *State) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try append(&out, text, opts, state);
    return out.toOwnedSlice();
}
