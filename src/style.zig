//! 排版风格：现代排版的默认参数
//! 参考 Typst 的 typst.toml 默认值与 LaTeX 的排版常数

const std = @import("std");
const units = @import("units.zig");
const fonts = @import("fonts.zig");
const ast = @import("ast.zig");

pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,

    pub fn black() Color {
        return .{ .r = 0, .g = 0, .b = 0 };
    }
    pub fn parse(text: []const u8) ?Color {
        const s = std.mem.trim(u8, text, " \t\r\n");
        if (s.len == 0) return null;
        if (s[0] == '#') {
            const hex = s[1..];
            if (hex.len == 6) {
                const v = std.fmt.parseInt(u32, hex, 16) catch return null;
                return .{ .r = @as(f64, @floatFromInt((v >> 16) & 0xFF)) / 255.0, .g = @as(f64, @floatFromInt((v >> 8) & 0xFF)) / 255.0, .b = @as(f64, @floatFromInt(v & 0xFF)) / 255.0 };
            }
            if (hex.len == 3) {
                const v = std.fmt.parseInt(u32, hex, 16) catch return null;
                return .{ .r = @as(f64, @floatFromInt((v >> 8) & 0xF)) * 17.0 / 255.0, .g = @as(f64, @floatFromInt((v >> 4) & 0xF)) * 17.0 / 255.0, .b = @as(f64, @floatFromInt(v & 0xF)) * 17.0 / 255.0 };
            }
            return null;
        }
        return namedColor(s);
    }

    pub fn namedColor(name: []const u8) ?Color {
        if (std.mem.eql(u8, name, "black")) return Color.black();
        if (std.mem.eql(u8, name, "white")) return .{ .r = 1, .g = 1, .b = 1 };
        if (std.mem.eql(u8, name, "red")) return .{ .r = 0.8, .g = 0.16, .b = 0.16 };
        if (std.mem.eql(u8, name, "blue")) return .{ .r = 0.16, .g = 0.36, .b = 0.78 };
        if (std.mem.eql(u8, name, "green")) return .{ .r = 0.18, .g = 0.55, .b = 0.34 };
        if (std.mem.eql(u8, name, "gray")) return .{ .r = 0.45, .g = 0.47, .b = 0.5 };
        if (std.mem.eql(u8, name, "muted")) return .{ .r = 0.42, .g = 0.44, .b = 0.48 };
        if (std.mem.eql(u8, name, "accent")) return .{ .r = 0.16, .g = 0.36, .b = 0.78 };
        return null;
    }
};

/// 页码样式（对应 LaTeX 的 \arabic / \roman / \alph）
pub const NumberStyle = enum { arabic, roman, roman_lower, letters };

const roman_pairs = [_]struct { v: usize, s: []const u8 }{
    .{ .v = 1000, .s = "M" },
    .{ .v = 900, .s = "CM" },
    .{ .v = 500, .s = "D" },
    .{ .v = 400, .s = "CD" },
    .{ .v = 100, .s = "C" },
    .{ .v = 90, .s = "XC" },
    .{ .v = 50, .s = "L" },
    .{ .v = 40, .s = "XL" },
    .{ .v = 10, .s = "X" },
    .{ .v = 9, .s = "IX" },
    .{ .v = 5, .s = "V" },
    .{ .v = 4, .s = "IV" },
    .{ .v = 1, .s = "I" },
};

pub fn formatNumber(style: NumberStyle, n: usize, allocator: std.mem.Allocator) []const u8 {
    switch (style) {
        .arabic => return std.fmt.allocPrint(allocator, "{d}", .{n}) catch "",
        .letters => {
            if (n == 0) return "";
            var out = std.array_list.Managed(u8).init(allocator);
            var i: usize = n;
            var digits: [16]u8 = undefined;
            var count: usize = 0;
            while (i > 0) {
                i -= 1;
                digits[count] = 'a' + @as(u8, @intCast(i % 26));
                count += 1;
                i /= 26;
            }
            var k = count;
            while (k > 0) {
                k -= 1;
                out.append(digits[k]) catch return "";
            }
            return out.toOwnedSlice() catch "";
        },
        .roman, .roman_lower => {
            var out = std.array_list.Managed(u8).init(allocator);
            var value = n;
            for (roman_pairs) |p| {
                while (value >= p.v) {
                    out.appendSlice(p.s) catch return "";
                    value -= p.v;
                }
            }
            const s = out.toOwnedSlice() catch return "";
            if (style == .roman_lower) {
                for (s, 0..) |*c, i| c.* = std.ascii.toLower(s[i]);
            }
            return s;
        },
    }
}

fn parseFamily(value: []const u8) fonts.Family {
    if (std.mem.eql(u8, value, "serif")) return .serif;
    if (std.mem.eql(u8, value, "mono")) return .mono;
    return .sans;
}

fn parseNumberStyle(value: []const u8) NumberStyle {
    if (std.mem.eql(u8, value, "roman")) return .roman;
    if (std.mem.eql(u8, value, "roman_lower")) return .roman_lower;
    if (std.mem.eql(u8, value, "letters")) return .letters;
    return .arabic;
}

pub const Style = struct {
    // 页面
    paper: units.Paper,
    margins: units.Margins,

    // 字体
    family: fonts.Family,
    heading_family: fonts.Family,
    size: f64,
    leading: f64,
    measure: f64,

    // 段落
    parskip: f64,
    indent: f64,
    justify: bool,
    hyphen: bool,
    /// TeX 的 spacefactor：句末标点后空格加宽
    spacefactor: bool = true,
    /// TeX 的 lineskip：行盒相碰时行与行之间的最小间隙（行距模型见 docs/typography.md）
    lineskip: f64 = 0.0,
    /// 字距（letter-spacing），单位为 pt；0 表示按字体度量
    tracking: f64 = 0.0,
    /// 标题字距，通常取负值（大字号需要收紧）
    heading_tracking: f64 = 0.0,
    /// 段首至少保留的行数（CSS orphans / TeX \clubpenalty）
    orphans: usize = 2,
    /// 段末至少带到下一页的行数（CSS widows / TeX \widowpenalty）
    widows: usize = 2,

    // 标题
    heading_sizes: [6]f64,
    heading_before: [6]f64,
    heading_after: [6]f64,

    // 细节
    footnote_size: f64,
    code_size: f64,
    quote_size: f64,
    caption_size: f64,
    header_size: f64,
    math_size: f64,

    // 颜色
    text_color: Color,
    muted_color: Color,
    accent_color: Color,

    // 行为
    numbering: bool,
    toc: bool,
    heading_autonumber: bool,
    lang: []const u8 = "en",
    /// 目录最多包含到第几级标题
    toc_depth: usize = 6,
    /// 页码样式；front_matter_depth 之前的页使用 front_number_style
    page_number_style: NumberStyle = .arabic,
    front_number_style: NumberStyle = .roman_lower,
    front_matter_depth: usize = 0,

    // 多栏排版
    columns: usize = 1,
    column_gap: f64 = 18.0,
    /// 首面（标题页）不显示页眉页脚
    plain_first_page: bool = false,

    // 页眉页脚
    header_left: ?[]const u8,
    header_center: ?[]const u8,
    header_right: ?[]const u8,
    footer_left: ?[]const u8,
    footer_center: ?[]const u8,
    footer_right: ?[]const u8,

    pub fn defaults() Style {
        var s = Style{
            .paper = units.parsePaper("A4"),
            .margins = units.Margins{ .top = 72, .right = 72, .bottom = 72, .left = 72 },
            .family = .sans,
            .heading_family = .sans,
            .size = 10.0,
            .leading = 15.0,
            .measure = 0, // 由页面宽度决定
            .parskip = 7.0,
            .indent = 0,
            .justify = false,
            .hyphen = true,
            .spacefactor = true,
            .lineskip = 0.0,
            .tracking = 0.0,
            .heading_tracking = -0.012,
            .heading_sizes = .{ 17.0, 13.5, 11.5, 10.5, 10.0, 10.0 },
            .heading_before = .{ 18.0, 14.0, 12.0, 10.0, 9.0, 9.0 },
            .heading_after = .{ 8.0, 7.0, 6.0, 5.0, 5.0, 5.0 },
            .footnote_size = 8.0,
            .code_size = 8.5,
            .quote_size = 9.5,
            .caption_size = 8.5,
            .header_size = 8.0,
            .math_size = 10.0,
            .text_color = Color.black(),
            .muted_color = .{ .r = 0.42, .g = 0.44, .b = 0.48 },
            .accent_color = .{ .r = 0.16, .g = 0.36, .b = 0.78 },
            .numbering = true,
            .toc = false,
            .heading_autonumber = true,
            .header_left = null,
            .header_center = null,
            .header_right = null,
            .footer_left = null,
            .footer_center = null,
            .footer_right = null,
        };
        s.measure = s.paper.width - s.margins.left - s.margins.right;
        return s;
    }

    pub fn fromMetadata(meta: *const ast.Metadata) Style {
        var s = defaults();
        if (meta.get("paper")) |p| s.paper = units.parsePaper(p);
        if (meta.get("margin")) |m| s.margins = units.parseMargins(m, units.cm);
        if (meta.get("margin_top")) |m| s.margins.top = units.parseLength(m, units.cm) orelse s.margins.top;
        if (meta.get("margin_bottom")) |m| s.margins.bottom = units.parseLength(m, units.cm) orelse s.margins.bottom;
        if (meta.get("margin_left")) |m| s.margins.left = units.parseLength(m, units.cm) orelse s.margins.left;
        if (meta.get("margin_right")) |m| s.margins.right = units.parseLength(m, units.cm) orelse s.margins.right;

        if (meta.get("font")) |f| s.family = parseFamily(f);
        if (meta.get("heading_font")) |f| s.heading_family = parseFamily(f);
        if (meta.get("fontsize")) |v| {
            if (units.parseLength(v, units.pt)) |sz| {
                s.size = sz;
                s.leading = sz * 1.5;
            }
        }
        if (meta.get("leading")) |v| {
            if (units.parseLength(v, s.size)) |l| s.leading = l;
        }
        if (meta.get("measure")) |v| {
            if (units.parseLength(v, s.size)) |m| s.measure = m;
        }
        if (meta.get("parskip")) |v| {
            if (units.parseLength(v, s.size)) |p| s.parskip = p;
        }
        if (meta.get("indent")) |v| {
            if (units.parseLength(v, s.size)) |i| s.indent = i;
        }
        if (meta.get("justify")) |v| s.justify = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
        if (meta.get("hyphen")) |v| s.hyphen = !(std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off"));
        if (meta.get("numbering")) |v| {
            s.numbering = !(std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "false"));
            s.heading_autonumber = s.numbering;
        }
        if (meta.get("spacefactor")) |v| s.spacefactor = !(std.mem.eql(u8, v, "none") or std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off"));
        if (meta.get("lineskip")) |v| {
            if (units.parseLength(v, s.size)) |l| s.lineskip = l;
        }
        if (meta.get("tracking")) |v| {
            if (units.parseLength(v, s.size)) |l| s.tracking = l;
        }
        if (meta.get("heading_tracking")) |v| {
            if (units.parseLength(v, s.size)) |l| s.heading_tracking = l;
        }
        if (meta.get("toc")) |v| s.toc = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");
        if (meta.get("color")) |v| {
            if (Color.parse(v)) |c| s.text_color = c;
        }
        if (meta.get("accent_color")) |v| {
            if (Color.parse(v)) |c| s.accent_color = c;
        }
        if (meta.get("lang")) |v| s.lang = v;
        if (meta.get("muted_color")) |v| {
            if (Color.parse(v)) |c| s.muted_color = c;
        }
        if (meta.get("columns")) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch 0;
            if (n > 0) s.columns = n;
        }
        if (meta.get("column_gap")) |v| {
            if (units.parseLength(v, s.size)) |g| s.column_gap = g;
        }
        if (meta.get("toc_depth")) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch 0;
            if (n > 0) s.toc_depth = n;
        }
        if (meta.get("orphans")) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch 0;
            if (n > 0) s.orphans = n;
        }
        if (meta.get("widows")) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch 0;
            if (n > 0) s.widows = n;
        }
        if (meta.get("pagenum")) |v| s.page_number_style = parseNumberStyle(v);
        if (meta.get("front_pagenum")) |v| s.front_number_style = parseNumberStyle(v);
        if (meta.get("front_matter")) |v| {
            const n = std.fmt.parseInt(usize, v, 10) catch 0;
            s.front_matter_depth = n;
        }
        if (meta.get("plain_first_page")) |v| s.plain_first_page = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "yes");

        // 细节字号：脚注、代码、引用、图注、页眉、数学
        if (meta.get("footnote_size")) |v| {
            if (units.parseLength(v, s.size)) |l| s.footnote_size = l;
        }
        if (meta.get("code_size")) |v| {
            if (units.parseLength(v, s.size)) |l| s.code_size = l;
        }
        if (meta.get("quote_size")) |v| {
            if (units.parseLength(v, s.size)) |l| s.quote_size = l;
        }
        if (meta.get("caption_size")) |v| {
            if (units.parseLength(v, s.size)) |l| s.caption_size = l;
        }
        if (meta.get("header_size")) |v| {
            if (units.parseLength(v, s.size)) |l| s.header_size = l;
        }
        if (meta.get("math_size")) |v| {
            if (units.parseLength(v, s.size)) |l| s.math_size = l;
        }
        // 标题前后间距：单值作用于全部层级
        if (meta.get("heading_before")) |v| {
            if (units.parseLength(v, s.size)) |l| {
                for (0..6) |i| s.heading_before[i] = l;
            }
        }
        if (meta.get("heading_after")) |v| {
            if (units.parseLength(v, s.size)) |l| {
                for (0..6) |i| s.heading_after[i] = l;
            }
        }

        s.header_left = meta.get("header_left");
        s.header_center = meta.get("header_center");
        s.header_right = meta.get("header_right");
        s.footer_left = meta.get("footer_left");
        s.footer_center = meta.get("footer_center");
        s.footer_right = meta.get("footer_right");

        if (meta.get("measure") == null) s.measure = s.paper.width - s.margins.left - s.margins.right;
        return s;
    }

    /// 版心宽度：measure 不能超过纸张减去页边距的实际可用宽度
    pub fn contentWidth(self: *const Style) f64 {
        const avail = self.paper.width - self.margins.left - self.margins.right;
        if (self.measure <= 0 or self.measure > avail) return avail;
        return self.measure;
    }

    /// 单栏宽度（多栏排版时用于断行与绘制）
    pub fn columnWidth(self: *const Style) f64 {
        const total = self.contentWidth();
        if (self.columns <= 1) return total;
        const gap = self.column_gap * @as(f64, @floatFromInt(self.columns - 1));
        const w = (total - gap) / @as(f64, @floatFromInt(self.columns));
        return if (w > 0) w else total;
    }

    pub fn columnLeft(self: *const Style, index: usize) f64 {
        if (index == 0) return self.margins.left;
        return self.margins.left + @as(f64, @floatFromInt(index)) * (self.columnWidth() + self.column_gap);
    }

    /// 图、表、清单、公式的编号前缀，按语言选择
    pub fn figure_label(self: *const Style) []const u8 {
        return if (std.mem.eql(u8, self.lang, "zh")) "图" else "Figure";
    }

    pub fn table_label(self: *const Style) []const u8 {
        return if (std.mem.eql(u8, self.lang, "zh")) "表" else "Table";
    }

    pub fn listing_label(self: *const Style) []const u8 {
        return if (std.mem.eql(u8, self.lang, "zh")) "清单" else "Listing";
    }

    pub fn equation_label(self: *const Style) []const u8 {
        return if (std.mem.eql(u8, self.lang, "zh")) "式" else "Eq.";
    }

    pub fn bibliography_label(self: *const Style) []const u8 {
        return if (std.mem.eql(u8, self.lang, "zh")) "参考文献" else "References";
    }

    pub fn toc_title(self: *const Style) []const u8 {
        return if (std.mem.eql(u8, self.lang, "zh")) "目录" else "Contents";
    }
};
