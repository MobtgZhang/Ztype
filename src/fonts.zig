//! 字体与字形度量
//! PDF 后端使用 base-14 标准字体，HTML 后端使用与之对应的 CSS 字体栈

const std = @import("std");
const m = @import("fontmetrics.zig");

pub const Font = enum(u8) {
    helvetica,
    helvetica_bold,
    helvetica_oblique,
    times,
    times_bold,
    times_italic,
    courier,
    courier_bold,
    symbol,
    cjk,
};

pub const Family = enum { sans, serif, mono };

pub const Variant = enum { regular, bold, italic };

pub fn familyFont(family: Family, variant: Variant) Font {
    switch (family) {
        .sans => switch (variant) {
            .regular => return .helvetica,
            .bold => return .helvetica_bold,
            .italic => return .helvetica_oblique,
        },
        .serif => switch (variant) {
            .regular => return .times,
            .bold => return .times_bold,
            .italic => return .times_italic,
        },
        .mono => switch (variant) {
            .regular => return .courier,
            .bold => return .courier_bold,
            .italic => return .courier,
        },
    }
}

pub fn boldVariant(font: Font) Font {
    switch (font) {
        .helvetica, .helvetica_oblique => return .helvetica_bold,
        .times, .times_italic => return .times_bold,
        .courier => return .courier_bold,
        else => return font,
    }
}

pub const pdf_name = std.StaticStringMap([]const u8).initComptime(.{
    .{ "helvetica", "/F1" },
    .{ "helvetica_bold", "/F2" },
    .{ "helvetica_oblique", "/F3" },
    .{ "times", "/F4" },
    .{ "times_bold", "/F5" },
    .{ "times_italic", "/F6" },
    .{ "courier", "/F7" },
    .{ "courier_bold", "/F8" },
    .{ "symbol", "/F9" },
    .{ "cjk", "/F10" },
});

pub const css_name = std.StaticStringMap([]const u8).initComptime(.{
    .{ "helvetica", "\"Helvetica Neue\", Helvetica, Arial, sans-serif" },
    .{ "times", "\"Times New Roman\", Georgia, serif" },
    .{ "courier", "\"SF Mono\", \"JetBrains Mono\", Consolas, monospace" },
});

/// Unicode 标点回退到 WinAnsi 编码位置
pub fn winAnsiCode(cp: u21) ?u8 {
    if (cp < 256) return @intCast(cp);
    return switch (cp) {
        0x2013 => 0x96, // –
        0x2014 => 0x97, // —
        0x2018 => 0x91, // ‘
        0x2019 => 0x92, // ’
        0x201C => 0x93, // “
        0x201D => 0x94, // ”
        0x2022 => 0x95, // •
        0x2026 => 0x85, // …
        0x2020 => 0x80, // †
        0x2021 => 0x81, // ‡
        0x2030 => 0x89, // ‰
        0x2032 => 0x82, // ′
        0x2033 => 0x83, // ″
        0x2039 => 0x8B,
        0x203A => 0x9B,
        0x20AC => 0xA0, // €
        0x2122 => 0x99, // ™
        else => null,
    };
}

pub fn symbolGlyph(cp: u21) ?m.SymbolGlyph {
    var lo: usize = 0;
    var hi: usize = m.SymbolGlyphs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const g = m.SymbolGlyphs[mid];
        if (g.cp == cp) return g;
        if (g.cp < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

pub fn isCjk(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x11FF) or
        (cp >= 0x2E80 and cp <= 0x303F) or
        (cp >= 0x3040 and cp <= 0x30FF) or
        (cp >= 0x3100 and cp <= 0x312F) or
        (cp >= 0x3130 and cp <= 0x318F) or
        (cp >= 0x31A0 and cp <= 0x31BF) or
        (cp >= 0x31C0 and cp <= 0x31EF) or
        (cp >= 0x3200 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xA960 and cp <= 0xA97F) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0x20000 and cp <= 0x2FA1F);
}

fn tableWidth(table: [256]f64, cp: u21, size: f64) f64 {
    if (winAnsiCode(cp)) |code| return table[code] / 1000.0 * size;
    return 0.55 * size;
}

pub fn glyphWidth(cp: u21, font: Font, size: f64) f64 {
    switch (font) {
        .helvetica => return tableWidth(m.HelveticaWidths, cp, size),
        .helvetica_bold => return tableWidth(m.HelveticaBoldWidths, cp, size),
        .helvetica_oblique => return tableWidth(m.HelveticaObliqueWidths, cp, size),
        .times => return tableWidth(m.TimesWidths, cp, size),
        .times_bold => return tableWidth(m.TimesBoldWidths, cp, size),
        .times_italic => return tableWidth(m.TimesItalicWidths, cp, size),
        .courier => return tableWidth(m.CourierWidths, cp, size),
        .courier_bold => return tableWidth(m.CourierBoldWidths, cp, size),
        .symbol => {
            if (symbolGlyph(cp)) |g| return g.width / 1000.0 * size;
            return tableWidth(m.HelveticaWidths, cp, size);
        },
        .cjk => {
            if (isCjk(cp)) return size;
            if (cp >= 0xFF61 and cp <= 0xFFDC) return 0.5 * size;
            return 0.5 * size;
        },
    }
}

/// 斜体补偿：斜体字形在基线上的额外右向突出量
pub fn italicCorrection(cp: u21, font: Font, size: f64) f64 {
    if (font != .times_italic and font != .helvetica_oblique) return 0;
    var c: f64 = 0;
    if (cp < 256) c = m.ItalicCorrection[cp] else c = m.symbolItalicCorrection(cp);
    if (c <= 0) return 0;
    return c / 1000.0 * size;
}

/// 字距调整量（units/1000 em）。等宽字体与 CJK 字体不做 kerning。
pub fn kernUnits(cp1: u21, cp2: u21, font: Font) i32 {
    if (font == .cjk or font == .courier or font == .courier_bold) return 0;
    if (cp1 >= 256 or cp2 >= 256) return 0;
    const table = switch (font) {
        .times, .times_bold, .times_italic, .symbol => m.TimesKerns,
        else => m.HelveticaKerns,
    };
    const key = [2]u8{ @intCast(cp1), @intCast(cp2) };
    return table.get(key[0..]) orelse 0;
}

/// 字距调整量（pt）
pub fn kern(cp1: u21, cp2: u21, font: Font, size: f64) f64 {
    const u = kernUnits(cp1, cp2, font);
    if (u == 0) return 0;
    return @as(f64, @floatFromInt(u)) / 1000.0 * size;
}

pub fn measure(text: []const u8, font: Font, size: f64) f64 {
    var view = std.unicode.Utf8View.init(text) catch return @as(f64, @floatFromInt(text.len)) * 0.55 * size;
    var iter = view.iterator();
    var total: f64 = 0;
    var prev: ?u21 = null;
    while (iter.nextCodepoint()) |cp| {
        if (prev) |p| total += kern(p, cp, font, size);
        total += glyphWidth(cp, font, size);
        prev = cp;
    }
    return total;
}

pub fn ascent(font: Font, size: f64) f64 {
    return switch (font) {
        .helvetica, .helvetica_bold, .helvetica_oblique => 0.718 * size,
        .times, .times_bold, .times_italic => 0.683 * size,
        .courier, .courier_bold => 0.629 * size,
        .symbol => 0.698 * size,
        .cjk => 0.88 * size,
    };
}

pub fn descent(font: Font, size: f64) f64 {
    return switch (font) {
        .helvetica, .helvetica_bold, .helvetica_oblique => 0.207 * size,
        .times, .times_bold, .times_italic => 0.217 * size,
        .courier, .courier_bold => 0.157 * size,
        .symbol => 0.197 * size,
        .cjk => 0.12 * size,
    };
}

/// x 高度（小写字母高度），用于上下标定位与根号度量
pub fn xHeight(font: Font, size: f64) f64 {
    return switch (font) {
        .helvetica, .helvetica_bold, .helvetica_oblique => 0.519 * size,
        .times, .times_bold, .times_italic => 0.448 * size,
        .courier, .courier_bold => 0.414 * size,
        .symbol => 0.448 * size,
        .cjk => 0.72 * size,
    };
}

/// 把 UTF-8 文本按 CJK / 非 CJK 切段，用于 PDF 字体切换
pub const Segment = struct { text: []const u8, is_cjk: bool };

pub fn segments(allocator: std.mem.Allocator, text: []const u8) ![]Segment {
    var out = std.array_list.Managed(Segment).init(allocator);
    var view = std.unicode.Utf8View.init(text) catch {
        try out.append(.{ .text = text, .is_cjk = false });
        return out.toOwnedSlice();
    };
    var iter = view.iterator();
    var start: usize = 0;
    var current: ?bool = null;

    while (iter.nextCodepoint()) |cp| {
        const cjk = isCjk(cp);
        if (current) |cur| {
            if (cur != cjk) {
                try out.append(.{ .text = text[start..iter.i], .is_cjk = cur });
                start = iter.i;
                current = cjk;
            }
        } else {
            current = cjk;
        }
    }
    if (start < text.len) try out.append(.{ .text = text[start..], .is_cjk = current.? });
    return out.toOwnedSlice();
}
