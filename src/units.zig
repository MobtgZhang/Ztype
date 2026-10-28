//! 长度单位与纸张规格
//! 支持 cm / mm / in / pt / bp / em，参考 LaTeX 与 Typst 的度量体系

const std = @import("std");

/// 所有内部长度均以 pt 为单位
pub const pt: f64 = 1.0;
pub const inch: f64 = 72.0;
pub const cm: f64 = 28.3464567;
pub const mm: f64 = 2.83464567;

/// 解析长度，未指定单位时按 base_unit 处理
pub fn parseLength(text: []const u8, base_unit: f64) ?f64 {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len == 0) return null;

    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.' or s[i] == '-')) i += 1;
    const number = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    const unit = std.mem.trim(u8, s[i..], " ");

    const factor = unitFactor(unit, base_unit) orelse return null;
    return number * factor;
}

/// 单位 -> 相对 pt 的系数；无单位时回落到 base_unit
pub fn unitFactor(unit: []const u8, base_unit: f64) ?f64 {
    if (unit.len == 0) return base_unit;
    if (std.mem.eql(u8, unit, "pt")) return pt;
    if (std.mem.eql(u8, unit, "in")) return inch;
    if (std.mem.eql(u8, unit, "cm")) return cm;
    if (std.mem.eql(u8, unit, "mm")) return mm;
    if (std.mem.eql(u8, unit, "bp")) return base_unit / 12.0; // basis point = 1/12 em
    if (std.mem.eql(u8, unit, "em")) return base_unit;
    if (std.mem.eql(u8, unit, "ex")) return base_unit * 0.5;
    return null;
}

pub const Paper = struct { name: []const u8, width: f64, height: f64 };

pub fn paper(name: []const u8) ?Paper {
    const n = std.mem.trim(u8, name, " \t\r\n");
    if (std.mem.eql(u8, n, "A0")) return .{ .name = "A0", .width = 841 * mm, .height = 1189 * mm };
    if (std.mem.eql(u8, n, "A1")) return .{ .name = "A1", .width = 594 * mm, .height = 841 * mm };
    if (std.mem.eql(u8, n, "A2")) return .{ .name = "A2", .width = 420 * mm, .height = 594 * mm };
    if (std.mem.eql(u8, n, "A3")) return .{ .name = "A3", .width = 297 * mm, .height = 420 * mm };
    if (std.mem.eql(u8, n, "A4")) return .{ .name = "A4", .width = 210 * mm, .height = 297 * mm };
    if (std.mem.eql(u8, n, "A5")) return .{ .name = "A5", .width = 148 * mm, .height = 210 * mm };
    if (std.mem.eql(u8, n, "A6")) return .{ .name = "A6", .width = 105 * mm, .height = 148 * mm };
    if (std.mem.eql(u8, n, "Letter")) return .{ .name = "Letter", .width = 216 * mm, .height = 279 * mm };
    if (std.mem.eql(u8, n, "Legal")) return .{ .name = "Legal", .width = 216 * mm, .height = 356 * mm };
    if (std.mem.eql(u8, n, "11x17")) return .{ .name = "11x17", .width = 279 * mm, .height = 432 * mm };
    return null;
}

/// 解析纸张：命名规格，或 `210x297mm` 这样的自定义尺寸
pub fn parsePaper(text: []const u8) Paper {
    const s = std.mem.trim(u8, text, " \t\r\n");
    if (paper(s)) |p| return p;

    if (std.mem.indexOfScalar(u8, s, 'x')) |sep| {
        // 自定义尺寸：后缀单位作用于两个维度，例如 `80x40mm`
        const b_str = std.mem.trim(u8, s[sep + 1 ..], " ");
        var i: usize = 0;
        while (i < b_str.len and (std.ascii.isDigit(b_str[i]) or b_str[i] == '.' or b_str[i] == '-')) i += 1;
        const base = unitFactor(std.mem.trim(u8, b_str[i..], " "), cm) orelse cm;
        const a = parseLength(s[0..sep], base);
        const b = parseLength(b_str, base);
        if (a != null and b != null) {
            return .{ .name = s, .width = a.?, .height = b.? };
        }
    }
    return paper("A4").?;
}

pub const Margins = struct { top: f64, right: f64, bottom: f64, left: f64 };

pub fn parseMargins(value: []const u8, base_unit: f64) Margins {
    const v = parseLength(value, base_unit) orelse 72;
    return .{ .top = v, .right = v, .bottom = v, .left = v };
}
