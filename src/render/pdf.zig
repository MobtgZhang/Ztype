//! Ztype PDF 后端
//! 消费排版引擎的分页结果，生成 PDF 1.7 文档：
//!   - 多页、base-14 标准字体、Symbol 数学字体、Type0 CJK 字体
//!   - 书签大纲、内部/外部链接注释、JPEG 图片嵌入
//!
//! 固定对象编号：1 Catalog、2 Pages、3 Outlines、4 Info、5-14 字体、
//! 15-24 字体描述符（24 为 CJK）、25 CIDFont；其余为页面、内容流、注释与图片。

const std = @import("std");
const engine = @import("../engine.zig");
const fonts = @import("../fonts.zig");
const style = @import("../style.zig");
const metrics = @import("../fontmetrics.zig");

const Allocator = std.mem.Allocator;

fn appendPrint(list: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(list.allocator, fmt, args);
    try list.appendSlice(s);
}


const CATALOG_ID: usize = 1;
const PAGES_ID: usize = 2;
const OUTLINE_ID: usize = 3;
const INFO_ID: usize = 4;
const FONT_BASE: usize = 5;
const DESC_BASE: usize = 15;
const CJK_DESC_ID: usize = 24;
const CIDFONT_ID: usize = 25;

const FontInfo = struct {
    base_font: []const u8,
    ascent: f64,
    descent: f64,
    flags: i32,
    bbox: [4]f64,
    italic: f64,
    stem_v: f64,
};

const font_infos = [10]FontInfo{
    .{ .base_font = "Helvetica", .ascent = 718, .descent = -207, .flags = 32, .bbox = .{ -166, -211, 1000, 942 }, .italic = 0, .stem_v = 88 },
    .{ .base_font = "Helvetica-Bold", .ascent = 718, .descent = -207, .flags = 32, .bbox = .{ -166, -250, 1000, 921 }, .italic = 0, .stem_v = 136 },
    .{ .base_font = "Helvetica-Oblique", .ascent = 718, .descent = -207, .flags = 32, .bbox = .{ -170, -211, 1132, 942 }, .italic = -12, .stem_v = 88 },
    .{ .base_font = "Times-Roman", .ascent = 683, .descent = -217, .flags = 32, .bbox = .{ -169, -211, 1010, 942 }, .italic = 0, .stem_v = 83 },
    .{ .base_font = "Times-Bold", .ascent = 683, .descent = -217, .flags = 32, .bbox = .{ -169, -225, 1012, 938 }, .italic = 0, .stem_v = 136 },
    .{ .base_font = "Times-Italic", .ascent = 683, .descent = -217, .flags = 32, .bbox = .{ -169, -211, 1010, 942 }, .italic = -11, .stem_v = 76 },
    .{ .base_font = "Courier", .ascent = 629, .descent = -157, .flags = 32, .bbox = .{ -471, -211, 1204, 942 }, .italic = 0, .stem_v = 105 },
    .{ .base_font = "Courier-Bold", .ascent = 629, .descent = -157, .flags = 32, .bbox = .{ -471, -211, 1204, 942 }, .italic = 0, .stem_v = 130 },
    .{ .base_font = "Symbol", .ascent = 698, .descent = -197, .flags = 4, .bbox = .{ -169, -211, 1010, 942 }, .italic = 0, .stem_v = 83 },
    .{ .base_font = "STSong-Light", .ascent = 880, .descent = -120, .flags = 4, .bbox = .{ -100, -200, 1000, 900 }, .italic = 0, .stem_v = 90 },
};

const PageLink = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    target: []const u8,
};

const PageRecord = struct {
    id: usize,
    content_id: usize,
    links: []PageLink,
    images: []usize,
    resources: []const u8,
    width: f64,
    height: f64,
    annots: []const u8 = "",
};

const OutlineEntry = struct {
    level: u8,
    title: []const u8,
    page_id: usize,
    parent_index: usize,
    children: usize,
    id: usize,
};

const Pdf = struct {
    allocator: Allocator,
    io: std.Io,
    st: style.Style,
    objects: std.array_list.Managed(?[]const u8),
    heading_pages: *const std.StringHashMap(usize),

    fn newObject(self: *Pdf) usize {
        self.objects.append(null) catch {};
        return self.objects.items.len;
    }

    fn setObject(self: *Pdf, id: usize, body: []const u8) void {
        self.objects.items[id - 1] = body;
    }

    fn fontId(font: fonts.Font) usize {
        return FONT_BASE + @intFromEnum(font);
    }

    fn descId(font: fonts.Font) usize {
        if (font == .cjk) return CJK_DESC_ID;
        return DESC_BASE + @intFromEnum(font);
    }
};

pub fn render(
    allocator: Allocator,
    io: std.Io,
    pages: []engine.Page,
    st: style.Style,
    title: []const u8,
    author: []const u8,
    heading_pages: *const std.StringHashMap(usize),
    writer: anytype,
) !void {
    var pdf = Pdf{
        .allocator = allocator,
        .io = io,
        .st = st,
        .objects = std.array_list.Managed(?[]const u8).init(allocator),
        .heading_pages = heading_pages,
    };

    // 预分配固定对象：1 Catalog、2 Pages、3 Outlines、4 Info、5-14 字体、15-25 描述符/CIDFont
    for (0..25) |_| _ = pdf.newObject();
    try buildFonts(&pdf);

    const records = try buildPages(&pdf, pages);
    var page_ids = std.array_list.Managed(usize).init(allocator);
    for (records) |r| try page_ids.append(@as(usize, r.id));
    try buildAnnotations(&pdf, records);
    const outline = try buildOutline(&pdf, pages, records);

    for (records) |r| {
        pdf.setObject(r.id, try std.fmt.allocPrint(allocator, "<< /Type /Page /Parent {d} 0 R /MediaBox [0 0 {d:.2} {d:.2}] /Resources <<{s}>>{s} /Contents {d} 0 R >>", .{
            PAGES_ID,
            r.width,
            r.height,
            r.resources,
            r.annots,
            r.content_id,
        }));
    }

    const kids = try joinIds(allocator, page_ids.items);
    pdf.setObject(PAGES_ID, try std.fmt.allocPrint(allocator, "<< /Type /Pages /Count {d} /Kids [{s}] >>", .{ records.len, kids }));

    // 前置内容与正文使用不同页码样式时，写 /PageLabels，阅读器才能正确显示页码
    var labels_part: []const u8 = "";
    if (st.front_matter_depth > 0 and pages.len > 0) {
        const labels_id = pdf.newObject();
        pdf.setObject(labels_id, try std.fmt.allocPrint(allocator, "<< /Num [{s}] >>", .{try pageLabels(allocator, pages, st)}));
        labels_part = try std.fmt.allocPrint(allocator, " /PageLabels {d} 0 R", .{labels_id});
    }

    if (outline.len > 0) {
        var first: usize = 0;
        var last: usize = 0;
        for (outline) |e| {
            if (e.parent_index == 0) {
                if (first == 0) first = e.id;
                last = e.id;
            }
        }
        pdf.setObject(OUTLINE_ID, try std.fmt.allocPrint(allocator, "<< /Type /Outlines /First {d} 0 R /Last {d} 0 R /Count {d} >>", .{ first, last, outline.len }));
    } else {
        pdf.setObject(OUTLINE_ID, "<< /Type /Outlines /Count 0 >>");
    }

    var outlines_part: []const u8 = "";
    if (outline.len > 0) outlines_part = try std.fmt.allocPrint(allocator, " /Outlines {d} 0 R", .{OUTLINE_ID});
    pdf.setObject(CATALOG_ID, try std.fmt.allocPrint(allocator, "<< /Type /Catalog /Pages {d} 0 R{s}{s} /Info {d} 0 R >>", .{
        PAGES_ID,
        outlines_part,
        labels_part,
        INFO_ID,
    }));

    pdf.setObject(INFO_ID, try std.fmt.allocPrint(allocator, "<< /Title ({s}) /Author ({s}) /Creator (Ztype) >>", .{
        escapeLiteral(pdf.allocator, title),
        escapeLiteral(pdf.allocator, author),
    }));

    try serialize(&pdf, writer);
}

// ---------------------------------------------------------------- 字体

fn buildFonts(pdf: *Pdf) !void {
    for (0..10) |i| {
        const info = font_infos[i];
        const font: fonts.Font = @enumFromInt(i);
        const font_id = FONT_BASE + i;
        const desc_id = Pdf.descId(font);

        if (font == .cjk) {
            pdf.setObject(font_id, try std.fmt.allocPrint(pdf.allocator, "<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light /Encoding /UniGB-UCS2-H /DescendantFonts [{d} 0 R] >>", .{CIDFONT_ID}));
        } else {
            const enc = if (font == .symbol) "" else " /Encoding /WinAnsiEncoding";
            const widths = try widthsString(pdf.allocator, font);
            pdf.setObject(font_id, try std.fmt.allocPrint(pdf.allocator, "<< /Type /Font /Subtype /Type1 /BaseFont /{s}{s} /FirstChar 32 /LastChar 255 /Widths {s} /FontDescriptor {d} 0 R >>", .{
                info.base_font,
                enc,
                widths,
                desc_id,
            }));
        }

        pdf.setObject(desc_id, try std.fmt.allocPrint(pdf.allocator, "<< /Type /FontDescriptor /FontName /{s} /Flags {d} /FontBBox [{d} {d} {d} {d}] /ItalicAngle {d} /Ascent {d} /Descent {d} /CapHeight {d} /StemV {d} >>", .{
            info.base_font,
            info.flags,
            info.bbox[0],
            info.bbox[1],
            info.bbox[2],
            info.bbox[3],
            info.italic,
            info.ascent,
            info.descent,
            info.ascent * 0.72,
            info.stem_v,
        }));
    }

    pdf.setObject(CIDFONT_ID, "<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >> /FontDescriptor 24 0 R /DW 1000 /W [ 1 95 500 ] >>");
}

fn widthsString(allocator: Allocator, font: fonts.Font) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.append('[');
    for (32..256) |code| {
        var width: f64 = 500;
        if (font == .symbol) {
            for (metrics.SymbolGlyphs) |g| {
                if (g.code == code) {
                    width = g.width;
                    break;
                }
            }
        } else {
            const table = switch (font) {
                .helvetica => metrics.HelveticaWidths,
                .helvetica_bold => metrics.HelveticaBoldWidths,
                .helvetica_oblique => metrics.HelveticaObliqueWidths,
                .times => metrics.TimesWidths,
                .times_bold => metrics.TimesBoldWidths,
                .times_italic => metrics.TimesItalicWidths,
                .courier => metrics.CourierWidths,
                .courier_bold => metrics.CourierWidths,
                else => metrics.HelveticaWidths,
            };
            width = table[code];
        }
        try out.append(' ');
        try appendPrint(&out, "{d}", .{width});
    }
    try out.append(']');
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------- 页面

fn buildPages(pdf: *Pdf, pages: []engine.Page) ![]PageRecord {
    var records = std.array_list.Managed(PageRecord).init(pdf.allocator);
    const font_dict = try fontResources(pdf.allocator);

    for (pages) |page| {
        const page_id = pdf.newObject();
        const content_id = pdf.newObject();

        var links = std.array_list.Managed(PageLink).init(pdf.allocator);
        var images = std.array_list.Managed(usize).init(pdf.allocator);
        const content = try buildContent(pdf, page, &links, &images);
        pdf.setObject(content_id, try std.fmt.allocPrint(pdf.allocator, "<< /Length {d} >>\nstream\n{s}endstream", .{ content.len, content }));

        var resources = std.array_list.Managed(u8).init(pdf.allocator);
        try resources.appendSlice("/Font ");
        try resources.appendSlice(font_dict);
        try resources.appendSlice(" /ProcSet [/PDF /Text /ImageC]");
        if (images.items.len > 0) {
            try resources.appendSlice(" /XObject <<");
            for (images.items) |img_id| {
                try appendPrint(&resources, " /X{d} {d} 0 R", .{ img_id, img_id });
            }
            try resources.appendSlice(" >>");
        }

        try records.append(PageRecord{
            .id = page_id,
            .content_id = content_id,
            .links = try links.toOwnedSlice(),
            .images = try images.toOwnedSlice(),
            .resources = try resources.toOwnedSlice(),
            .width = page.width,
            .height = page.height,
        });
    }

    return records.toOwnedSlice();
}

fn fontResources(allocator: Allocator) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    try out.appendSlice("<<");
    for (0..10) |i| {
        try appendPrint(&out, " /F{d} {d} 0 R", .{ i + 1, FONT_BASE + i });
    }
    try out.appendSlice(" >>");
    return out.toOwnedSlice();
}

fn buildContent(pdf: *Pdf, page: engine.Page, links: *std.array_list.Managed(PageLink), images: *std.array_list.Managed(usize)) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(pdf.allocator);
    try buf.appendSlice("q\n");

    for (page.backgrounds.items) |r| try drawRect(&buf, r);
    for (page.items.items) |item| try drawItem(pdf, &buf, item, links, images);
    for (page.header.items) |item| try drawItem(pdf, &buf, item, links, images);
    for (page.footer.items) |item| try drawItem(pdf, &buf, item, links, images);

    try buf.appendSlice("Q\n");
    return buf.toOwnedSlice();
}

fn drawItem(pdf: *Pdf, buf: *std.array_list.Managed(u8), item: engine.Item, links: *std.array_list.Managed(PageLink), images: *std.array_list.Managed(usize)) !void {
    switch (item) {
        .text => |t| try drawText(pdf, buf, t, links),
        .rule => |r| try drawRule(buf, r),
        .rect => |r| try drawRect(buf, r),
        .image => |img| try drawImage(pdf, buf, img, images),
    }
}

fn drawText(pdf: *Pdf, buf: *std.array_list.Managed(u8), item: engine.TextItem, links: *std.array_list.Managed(PageLink)) !void {
    if (item.text.len == 0) return;

    var view = std.unicode.Utf8View.init(item.text) catch {
        try writeRun(buf, item, item.text, item.font);
        return;
    };

    var segment = std.array_list.Managed(u8).init(pdf.allocator);
    var current: ?fonts.Font = null;
    var x = item.x;

    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        const font = effectiveFont(cp, item.font);
        if (current) |cur| {
            if (cur != font) {
                try writeRun(buf, item, segment.items, cur);
                x += segmentWidth(pdf, segment.items, cur, item.size);
                segment.clearRetainingCapacity();
                current = font;
            }
        } else {
            current = font;
        }
        appendCodepoint(&segment, cp, font) catch return;
    }

    if (segment.items.len > 0) {
        try writeRun(buf, item, segment.items, current.?);
        x += segmentWidth(pdf, segment.items, current.?, item.size);
    }

    if (item.link) |target| {
        try links.append(PageLink{
            .x = item.x,
            .y = item.y - fonts.descent(item.font, item.size),
            .w = x - item.x,
            .h = fonts.ascent(item.font, item.size) + fonts.descent(item.font, item.size),
            .target = target,
        });
    }
}

fn effectiveFont(cp: u21, base: fonts.Font) fonts.Font {
    if (base == .cjk) return .cjk;
    if (fonts.isCjk(cp)) return .cjk;
    if (base == .symbol) return .symbol;
    if (fonts.winAnsiCode(cp) != null) return base;
    if (fonts.symbolGlyph(cp) != null) return .symbol;
    return base;
}

fn appendCodepoint(out: *std.array_list.Managed(u8), cp: u21, font: fonts.Font) !void {
    if (font == .cjk) {
        var bytes: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &bytes) catch return;
        try out.appendSlice(bytes[0..n]);
        return;
    }
    if (font == .symbol) {
        if (fonts.symbolGlyph(cp)) |g| {
            try out.append(g.code);
            return;
        }
    }
    if (fonts.winAnsiCode(cp)) |code| {
        try out.append(code);
        return;
    }
    var bytes: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &bytes) catch return;
    try out.appendSlice(bytes[0..n]);
}

fn segmentWidth(pdf: *Pdf, text: []const u8, font: fonts.Font, size: f64) f64 {
    _ = pdf;
    return fonts.measure(text, font, size);
}

fn writeRun(buf: *std.array_list.Managed(u8), item: engine.TextItem, text: []const u8, font: fonts.Font) !void {
    try buf.appendSlice("BT\n");
    try appendPrint(buf, "/F{d} {d:.2} Tf\n", .{ @intFromEnum(font) + 1, item.size });
    // 字距：PDF 的 Tc（character spacing），与引擎计入自然宽度的字距一致
    if (item.tracking != 0) try appendPrint(buf, "{d:.3} Tc\n", .{item.tracking});
    if (font == .cjk) {
        try appendPrint(buf, "{d} Tz\n", .{item.scale_x * 100.0});
    } else {
        try appendPrint(buf, "{d:.3} 0 0 {d:.3} 0 0 Tm\n", .{ item.scale_x, item.scale_y });
    }
    try appendPrint(buf, "{d:.2} {d:.2} Td\n", .{ item.x, item.y });
    try writeColor(buf, item.color, false);
    if (font == .cjk) {
        try buf.appendSlice("<");
        var view = std.unicode.Utf8View.init(text) catch {
            try buf.appendSlice("> Tj\nET\n");
            return;
        };
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| {
            try appendPrint(buf, "{X:04}", .{cp});
        }
        try buf.appendSlice("> Tj\nET\n");
        return;
    }

    // TJ 数组：把 kerning 直接写进文本流（等价于 TeX 的 kern 表）。
    // text 已经是字体编码后的字节串，按字节查字距表即可。
    try buf.append('[');
    var prev: ?u8 = null;
    var first = true;
    for (text) |c| {
        if (prev) |p| {
            const k = fonts.kernUnits(p, c, font);
            if (k != 0) try appendPrint(buf, " {d}", .{k});
        }
        if (first) {
            first = false;
        } else {
            try buf.append(' ');
        }
        try escapeLiteralTo(buf, &[1]u8{c});
        prev = c;
    }
    try buf.appendSlice("] TJ\nET\n");
}

fn drawRule(buf: *std.array_list.Managed(u8), r: engine.RuleItem) !void {
    try buf.appendSlice("q\n");
    try writeColor(buf, r.color, true);
    try appendPrint(buf, "{d:.2} w\n", .{r.thickness});
    try appendPrint(buf, "{d:.2} {d:.2} m {d:.2} {d:.2} l S\n", .{ r.x, r.y, r.x + r.w, r.y });
    try buf.appendSlice("Q\n");
}

fn drawRect(buf: *std.array_list.Managed(u8), r: engine.RectItem) !void {
    try buf.appendSlice("q\n");
    if (r.fill) |c| {
        try writeColor(buf, c, false);
        try appendPrint(buf, "{d:.2} {d:.2} {d:.2} {d:.2} re f\n", .{ r.x, r.y, r.w, r.h });
    } else if (r.stroke) |c| {
        try writeColor(buf, c, true);
        try appendPrint(buf, "{d:.2} w\n", .{0.5});
        try appendPrint(buf, "{d:.2} {d:.2} {d:.2} {d:.2} re S\n", .{ r.x, r.y, r.w, r.h });
    }
    try buf.appendSlice("Q\n");
}

fn drawImage(pdf: *Pdf, buf: *std.array_list.Managed(u8), img: engine.ImageItem, images: *std.array_list.Managed(usize)) !void {
    const id = embedJpeg(pdf, img.src);
    if (id == 0) return;
    try images.append(id);
    try buf.appendSlice("q\n");
    try appendPrint(buf, "{d:.2} 0 0 {d:.2} {d:.2} {d:.2} cm\n", .{ img.w, img.h, img.x, img.y });
    try appendPrint(buf, "/X{d} Do\n", .{id});
    try buf.appendSlice("Q\n");
}

fn embedJpeg(pdf: *Pdf, src: []const u8) usize {
    const data = std.Io.Dir.readFileAlloc(std.Io.Dir.cwd(), pdf.io, src, pdf.allocator, .limited(16 * 1024 * 1024)) catch return 0;
    if (data.len < 4 or data[0] != 0xFF or data[1] != 0xD8) return 0;

    var width: u16 = 0;
    var height: u16 = 0;
    var i: usize = 2;
    while (i + 9 < data.len) {
        if (data[i] != 0xFF) {
            i += 1;
            continue;
        }
        const marker = data[i + 1];
        const is_sof = (marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8);
        if (is_sof) {
            width = (@as(u16, data[i + 5]) << 8) | data[i + 6];
            height = (@as(u16, data[i + 7]) << 8) | data[i + 8];
            break;
        }
        const seg_len = (@as(u16, data[i + 2]) << 8) | data[i + 3];
        i += 2 + seg_len;
    }
    if (width == 0 or height == 0) return 0;

    const id = pdf.newObject();
    const body = std.fmt.allocPrint(pdf.allocator, "<< /Type /XObject /Subtype /Image /Width {d} /Height {d} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {d} >>\nstream\n", .{ width, height, data.len }) catch return id;
    pdf.setObject(id, std.fmt.allocPrint(pdf.allocator, "{s}{s}", .{ body, data }) catch body);
    return id;
}

fn writeColor(buf: *std.array_list.Managed(u8), c: engine.Color, stroke: bool) !void {
    try appendPrint(buf, "{d:.3} {d:.3} {d:.3} {s}\n", .{ c.r, c.g, c.b, if (stroke) "RG" else "rg" });
}

fn escapeLiteralTo(buf: *std.array_list.Managed(u8), text: []const u8) !void {
    try buf.append('(');
    for (text) |c| {
        switch (c) {
            '(' => try buf.appendSlice("\\("),
            ')' => try buf.appendSlice("\\)"),
            '\\' => try buf.appendSlice("\\\\"),
            '\r' => {},
            else => try buf.append(c),
        }
    }
    try buf.append(')');
}

fn escapeLiteral(allocator: Allocator, text: []const u8) []const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (text) |c| {
        switch (c) {
            '(' => out.appendSlice("\\(") catch {},
            ')' => out.appendSlice("\\)") catch {},
            '\\' => out.appendSlice("\\\\") catch {},
            else => out.append(c) catch {},
        }
    }
    return out.items;
}

fn linkAction(pdf: *Pdf, target: []const u8, page_id: usize, page_ids: []const usize) ![]const u8 {
    if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://") or std.mem.startsWith(u8, target, "mailto:")) {
        return std.fmt.allocPrint(pdf.allocator, "/A << /S /URI /URI ({s}) >>", .{escapeLiteral(pdf.allocator, target)});
    }
    if (pdf.heading_pages.get(target)) |page_number| {
        if (page_number >= 1 and page_number <= page_ids.len) {
            return std.fmt.allocPrint(pdf.allocator, "/Dest [{d} 0 R /XYZ null null null]", .{page_ids[page_number - 1]});
        }
    }
    _ = page_id;
    return "";
}

fn buildAnnotations(pdf: *Pdf, records: []PageRecord) !void {
    var page_ids = std.array_list.Managed(usize).init(pdf.allocator);
    for (records) |r| try page_ids.append(@as(usize, r.id));

    for (records, 0..) |r, i| {
        if (r.links.len == 0) continue;
        var ids = std.array_list.Managed(usize).init(pdf.allocator);
        for (r.links) |_| try ids.append(pdf.newObject());
        for (r.links, 0..) |l, j| {
            const rect = try std.fmt.allocPrint(pdf.allocator, "[{d:.2} {d:.2} {d:.2} {d:.2}]", .{ l.x, l.y, l.x + l.w, l.y + l.h });
            const action = try linkAction(pdf, l.target, r.id, page_ids.items);
            pdf.setObject(ids.items[j], try std.fmt.allocPrint(pdf.allocator, "<< /Type /Annot /Subtype /Link /Rect {s} /Border [0 0 0] /Parent {d} 0 R{s} >>", .{ rect, r.id, action }));
        }
        const joined = try joinIds(pdf.allocator, ids.items);
        records[i].annots = try std.fmt.allocPrint(pdf.allocator, " /Annots [{s}]", .{joined});
    }
}

// ---------------------------------------------------------------- 大纲

fn buildOutline(pdf: *Pdf, pages: []engine.Page, records: []PageRecord) ![]OutlineEntry {
    var entries = std.array_list.Managed(OutlineEntry).init(pdf.allocator);
    for (pages) |page| {
        for (page.bookmarks.items) |b| {
            try entries.append(OutlineEntry{
                .level = b.level,
                .title = b.title,
                .page_id = records[page.number - 1].id,
                .parent_index = 0,
                .children = 0,
                .id = 0,
            });
        }
    }

    var stack = std.array_list.Managed(usize).init(pdf.allocator);
    for (entries.items, 0..) |*e, i| {
        while (stack.items.len > 0) {
            const parent = entries.items[stack.items[stack.items.len - 1]];
            if (parent.level < e.level) break;
            _ = stack.pop();
        }
        if (stack.items.len > 0) e.parent_index = stack.items[stack.items.len - 1];
        if (e.parent_index != 0) entries.items[e.parent_index].children += 1;
        try stack.append(i);
    }

    for (entries.items) |*e| e.id = pdf.newObject();

    for (entries.items, 0..) |e, i| {
        var prev: usize = 0;
        var next: usize = 0;
        for (entries.items, 0..) |sibling, j| {
            if (sibling.parent_index != e.parent_index) continue;
            if (j < i) prev = sibling.id;
            if (j > i) {
                next = sibling.id;
                break;
            }
        }
        const parent_id = if (e.parent_index == 0) OUTLINE_ID else entries.items[e.parent_index].id;
        const prev_str = if (prev != 0) try std.fmt.allocPrint(pdf.allocator, " /Prev {d} 0 R", .{prev}) else "";
        const next_str = if (next != 0) try std.fmt.allocPrint(pdf.allocator, " /Next {d} 0 R", .{next}) else "";
        pdf.setObject(e.id, try std.fmt.allocPrint(pdf.allocator, "<< /Type /Outlines /Title ({s}) /Parent {d} 0 R /Dest [{d} 0 R /XYZ null null null] /Count {d}{s}{s} >>", .{
            escapeLiteral(pdf.allocator, e.title),
            parent_id,
            e.page_id,
            e.children,
            prev_str,
            next_str,
        }));
    }

    return entries.toOwnedSlice();
}

// ---------------------------------------------------------------- 输出

fn joinIds(allocator: Allocator, ids: []usize) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    for (ids, 0..) |id, i| {
        if (i > 0) try out.append(' ');
        try appendPrint(&out, "{d} 0 R", .{id});
    }
    return out.toOwnedSlice();
}

/// PDF 页码样式名：/D 十进制、/R 罗马、/r 小写罗马、/A 字母
fn numberStyleName(s: style.NumberStyle) []const u8 {
    return switch (s) {
        .arabic => "/D",
        .roman => "/R",
        .roman_lower => "/r",
        .letters => "/A",
    };
}

/// 按页码样式把页分组，生成 /Num 数组：`0 << /S /r >> 3 << /S /D >>`
fn pageLabels(allocator: Allocator, pages: []engine.Page, st: style.Style) ![]const u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    var i: usize = 0;
    while (i < pages.len) {
        const s = if (st.front_matter_depth > 0 and pages[i].number <= st.front_matter_depth) st.front_number_style else st.page_number_style;
        var j = i + 1;
        while (j < pages.len) {
            const js = if (st.front_matter_depth > 0 and pages[j].number <= st.front_matter_depth) st.front_number_style else st.page_number_style;
            if (js != s) break;
            j += 1;
        }
        if (out.items.len > 0) try out.append(' ');
        try appendPrint(&out, "{d} << /S {s} >>", .{ i, numberStyleName(s) });
        i = j;
    }
    return try out.toOwnedSlice();
}

fn serialize(pdf: *Pdf, writer: anytype) !void {
    var out = std.array_list.Managed(u8).init(pdf.allocator);
    var offsets = std.array_list.Managed(usize).init(pdf.allocator);

    try out.appendSlice("%PDF-1.7\n");
    for (pdf.objects.items, 1..) |body, id| {
        try offsets.append(out.items.len);
        try appendPrint(&out, "{d} 0 obj\n", .{id});
        if (body) |b| try out.appendSlice(b) else try out.appendSlice("null");
        try out.appendSlice("\nendobj\n");
    }

    const xref_offset = out.items.len;
    try appendPrint(&out, "xref\n0 {d}\n", .{pdf.objects.items.len + 1});
    try out.appendSlice("0000000000 00000 f \n");
    for (offsets.items) |off| {
        try appendPrint(&out, "{d:0>10} 00000 n \n", .{off});
    }
    try appendPrint(&out, "trailer\n<< /Size {d} /Root {d} 0 R /Info {d} 0 R >>\nstartxref\n{d}\n%%EOF\n", .{
        pdf.objects.items.len + 1,
        CATALOG_ID,
        INFO_ID,
        xref_offset,
    });

    try writer.writeAll(out.items);
}
