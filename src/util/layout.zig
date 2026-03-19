//! 页面布局设置（参考 LaTeX）
//! 支持纸张尺寸、页边距、页眉、页脚

const std = @import("std");
const ast = @import("../ast.zig");

/// 纸张规格（ISO + 常用）
pub const PaperSize = enum {
    A0,
    A1,
    A2,
    A3,
    A4,
    A5,
    A6,
    Letter,
    Legal,

    /// 返回 (宽, 高) 单位：点 pt (1 inch = 72 pt)
    pub fn dimensions(self: PaperSize) struct { w: f64, h: f64 } {
        return switch (self) {
            .A0 => .{ .w = 2384, .h = 3370 },
            .A1 => .{ .w = 1684, .h = 2384 },
            .A2 => .{ .w = 1191, .h = 1684 },
            .A3 => .{ .w = 842, .h = 1191 },
            .A4 => .{ .w = 595, .h = 842 },
            .A5 => .{ .w = 420, .h = 595 },
            .A6 => .{ .w = 297, .h = 420 },
            .Letter => .{ .w = 612, .h = 792 },
            .Legal => .{ .w = 612, .h = 1008 },
        };
    }
};

/// 从字符串解析纸张规格
pub fn parsePaper(s: []const u8) PaperSize {
    if (std.ascii.eqlIgnoreCase(s, "A0")) return .A0;
    if (std.ascii.eqlIgnoreCase(s, "A1")) return .A1;
    if (std.ascii.eqlIgnoreCase(s, "A2")) return .A2;
    if (std.ascii.eqlIgnoreCase(s, "A3")) return .A3;
    if (std.ascii.eqlIgnoreCase(s, "A4")) return .A4;
    if (std.ascii.eqlIgnoreCase(s, "A5")) return .A5;
    if (std.ascii.eqlIgnoreCase(s, "A6")) return .A6;
    if (std.ascii.eqlIgnoreCase(s, "Letter")) return .Letter;
    if (std.ascii.eqlIgnoreCase(s, "Legal")) return .Legal;
    return .A4; // 默认
}

/// 解析长度字符串为点 pt（如 "2.5cm", "1in", "72pt"）
pub fn parseLengthToPt(s: []const u8) f64 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len == 0) return 72; // 默认 1 inch

    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];
        if (std.ascii.isDigit(c) or c == '.' or (i == 0 and c == '-')) continue;
        break;
    }
    const num_str = trimmed[0..i];
    const unit = std.mem.trim(u8, if (i < trimmed.len) trimmed[i..] else "", " \t");

    const num = std.fmt.parseFloat(f64, num_str) catch 1.0;

    return if (std.ascii.eqlIgnoreCase(unit, "cm"))
        num * 28.346
    else if (std.ascii.eqlIgnoreCase(unit, "mm"))
        num * 2.8346
    else if (std.ascii.eqlIgnoreCase(unit, "in"))
        num * 72
    else if (std.ascii.eqlIgnoreCase(unit, "pt"))
        num
    else
        num * 28.346; // 默认按 cm
}

/// 页面布局配置
pub const PageLayout = struct {
    paper_w: f64 = 595,
    paper_h: f64 = 842,
    margin_top: f64 = 72,
    margin_bottom: f64 = 72,
    margin_left: f64 = 72,
    margin_right: f64 = 72,
    header_left: ?[]const u8 = null,
    header_center: ?[]const u8 = null,
    header_right: ?[]const u8 = null,
    footer_left: ?[]const u8 = null,
    footer_center: ?[]const u8 = null,
    footer_right: ?[]const u8 = null,

    /// 从文档元数据构建布局
    pub fn fromDoc(doc: *const ast.Document) PageLayout {
        var layout: PageLayout = .{};
        const m = doc.metadata orelse return layout;
        if (m.get("paper")) |p| {
            const d = parsePaper(p).dimensions();
            layout.paper_w = d.w;
            layout.paper_h = d.h;
        }
        if (m.get("margin")) |s| {
            const pt = parseLengthToPt(s);
            layout.margin_top = pt;
            layout.margin_bottom = pt;
            layout.margin_left = pt;
            layout.margin_right = pt;
        }
        if (m.get("margin_top")) |s| layout.margin_top = parseLengthToPt(s);
        if (m.get("margin_bottom")) |s| layout.margin_bottom = parseLengthToPt(s);
        if (m.get("margin_left")) |s| layout.margin_left = parseLengthToPt(s);
        if (m.get("margin_right")) |s| layout.margin_right = parseLengthToPt(s);
        if (m.get("header_left")) |s| layout.header_left = s;
        if (m.get("header_center")) |s| layout.header_center = s;
        if (m.get("header_right")) |s| layout.header_right = s;
        if (m.get("footer_left")) |s| layout.footer_left = s;
        if (m.get("footer_center")) |s| layout.footer_center = s;
        if (m.get("footer_right")) |s| layout.footer_right = s;
        return layout;
    }
};
