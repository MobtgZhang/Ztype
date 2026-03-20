//! Ztype PDF 渲染器
//! 生成 PDF 1.4 文档，支持多页、文本自动换行、CJK 字体、页码
//!
//! PDF 对象布局:
//!   1: Catalog
//!   2: Pages (parent)
//!   3: Font Helvetica (F1)
//!   4: Font Helvetica-Bold (F2)
//!   5: Font Helvetica-Oblique (F3)
//!   6: Font Courier (F4) — monospace
//!   7: CJK CIDFont Type0 (F5)
//!   8: CIDFont descendant
//!   9: ToUnicode CMap
//!   10+: Page objects and content streams

const std = @import("std");
const ast = @import("../ast.zig");
const cjk = @import("../util/cjk.zig");
const layout_mod = @import("../util/layout.zig");
const Resolver = @import("../resolver.zig").Resolver;

const FONT_HELVETICA = "/F1";
const FONT_HELVETICA_BOLD = "/F2";
const FONT_HELVETICA_OBLIQUE = "/F3";
const FONT_COURIER = "/F4";
const FONT_CJK = "/F5";

const FIXED_OBJ_COUNT = 9;

const PdfObj = struct {
    offset: usize = 0,
    data: []const u8,
};

/// Main PDF generation context — accumulates pages and serializes to PDF 1.4
const PdfBuilder = struct {
    allocator: std.mem.Allocator,
    pg: layout_mod.PageLayout,
    objects: std.array_list.Managed(PdfObj),
    page_ids: std.array_list.Managed(usize),
    current_content: std.array_list.Managed(u8),
    y: f64,
    page_count: usize,

    fn init(allocator: std.mem.Allocator, pg: layout_mod.PageLayout) PdfBuilder {
        return .{
            .allocator = allocator,
            .pg = pg,
            .objects = std.array_list.Managed(PdfObj).init(allocator),
            .page_ids = std.array_list.Managed(usize).init(allocator),
            .current_content = std.array_list.Managed(u8).init(allocator),
            .y = pg.paper_h - pg.margin_top,
            .page_count = 0,
        };
    }

    fn deinit(self: *PdfBuilder) void {
        for (self.objects.items) |obj| self.allocator.free(obj.data);
        self.objects.deinit();
        self.page_ids.deinit();
        self.current_content.deinit();
    }

    fn contentWidth(self: *const PdfBuilder) f64 {
        return self.pg.paper_w - self.pg.margin_left - self.pg.margin_right;
    }

    fn bottomLimit(self: *const PdfBuilder) f64 {
        return self.pg.margin_bottom + 30;
    }

    fn startPage(self: *PdfBuilder) !void {
        self.page_count += 1;
        self.y = self.pg.paper_h - self.pg.margin_top;
        self.current_content.clearRetainingCapacity();

        if (self.pg.header_left != null or self.pg.header_center != null or self.pg.header_right != null) {
            const header_y = self.pg.paper_h - self.pg.margin_top + 15;
            try self.current_content.appendSlice("BT\n");
            if (self.pg.header_left) |s| {
                try self.setFont(FONT_HELVETICA, 9);
                try self.moveTo(self.pg.margin_left, header_y);
                try self.showText(s);
            }
            if (self.pg.header_center) |s| {
                try self.setFont(FONT_HELVETICA, 9);
                const tw = cjk.measureTextWidth(s, 9);
                try self.moveTo(self.pg.margin_left + (self.contentWidth() - tw) / 2, header_y);
                try self.showText(s);
            }
            if (self.pg.header_right) |s| {
                try self.setFont(FONT_HELVETICA, 9);
                const tw = cjk.measureTextWidth(s, 9);
                try self.moveTo(self.pg.paper_w - self.pg.margin_right - tw, header_y);
                try self.showText(s);
            }
            try self.current_content.appendSlice("ET\n");
        }
    }

    fn endPage(self: *PdfBuilder) !void {
        // Footer with page number
        const footer_y = self.pg.margin_bottom - 15;
        try self.current_content.appendSlice("BT\n");

        if (self.pg.footer_left) |s| {
            try self.setFont(FONT_HELVETICA, 9);
            try self.moveTo(self.pg.margin_left, footer_y);
            try self.showText(s);
        }
        if (self.pg.footer_center) |s| {
            try self.setFont(FONT_HELVETICA, 9);
            const tw = cjk.measureTextWidth(s, 9);
            try self.moveTo(self.pg.margin_left + (self.contentWidth() - tw) / 2, footer_y);
            try self.showText(s);
        }
        if (self.pg.footer_right) |s| {
            try self.setFont(FONT_HELVETICA, 9);
            const tw = cjk.measureTextWidth(s, 9);
            try self.moveTo(self.pg.paper_w - self.pg.margin_right - tw, footer_y);
            try self.showText(s);
        }

        // Always show page number if no footer_center
        if (self.pg.footer_center == null) {
            try self.setFont(FONT_HELVETICA, 9);
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{self.page_count}) catch "?";
            const tw = cjk.measureTextWidth(num_str, 9);
            try self.moveTo(self.pg.margin_left + (self.contentWidth() - tw) / 2, footer_y);
            try self.showTextAscii(num_str);
        }

        try self.current_content.appendSlice("ET\n");

        // Horizontal rule above footer
        try self.current_content.writer().print("0.8 G\n{d:.1} {d:.1} m {d:.1} {d:.1} l S\n0 G\n", .{
            self.pg.margin_left,
            self.pg.margin_bottom,
            self.pg.paper_w - self.pg.margin_right,
            self.pg.margin_bottom,
        });

        const content_data = try self.allocator.dupe(u8, self.current_content.items);
        const stream_id = FIXED_OBJ_COUNT + self.page_ids.items.len * 2 + 2;
        const page_id = stream_id - 1;

        var page_buf = std.array_list.Managed(u8).init(self.allocator);
        defer page_buf.deinit();
        try page_buf.writer().print(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d:.0} {d:.0}] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R /F4 6 0 R /F5 7 0 R >> >> /Contents {d} 0 R >>",
            .{ self.pg.paper_w, self.pg.paper_h, stream_id },
        );

        try self.objects.append(.{ .data = try page_buf.toOwnedSlice() });

        var stream_buf = std.array_list.Managed(u8).init(self.allocator);
        defer stream_buf.deinit();
        try stream_buf.writer().print("<< /Length {d} >>\nstream\n", .{content_data.len});
        try stream_buf.appendSlice(content_data);
        self.allocator.free(content_data);
        try stream_buf.appendSlice("\nendstream");

        try self.objects.append(.{ .data = try stream_buf.toOwnedSlice() });
        try self.page_ids.append(page_id);
    }

    fn checkPageBreak(self: *PdfBuilder, needed: f64) !void {
        if (self.y - needed < self.bottomLimit()) {
            try self.endPage();
            try self.startPage();
        }
    }

    fn setFont(self: *PdfBuilder, font: []const u8, size: f64) !void {
        try self.current_content.writer().print("{s} {d:.0} Tf\n", .{ font, size });
    }

    fn moveTo(self: *PdfBuilder, x: f64, y: f64) !void {
        try self.current_content.writer().print("{d:.2} {d:.2} Td\n", .{ x, y });
    }

    fn showText(self: *PdfBuilder, s: []const u8) !void {
        if (cjk.hasNonAscii(s)) {
            const encoded = try cjk.utf8ToPdfHex(self.allocator, s);
            defer self.allocator.free(encoded);
            try self.current_content.appendSlice(encoded);
        } else {
            try self.current_content.append('(');
            for (s) |c| {
                switch (c) {
                    '\\' => try self.current_content.appendSlice("\\\\"),
                    '(' => try self.current_content.appendSlice("\\("),
                    ')' => try self.current_content.appendSlice("\\)"),
                    else => try self.current_content.append(c),
                }
            }
            try self.current_content.append(')');
        }
        try self.current_content.appendSlice(" Tj\n");
    }

    fn showTextAscii(self: *PdfBuilder, s: []const u8) !void {
        try self.current_content.append('(');
        for (s) |c| {
            switch (c) {
                '\\' => try self.current_content.appendSlice("\\\\"),
                '(' => try self.current_content.appendSlice("\\("),
                ')' => try self.current_content.appendSlice("\\)"),
                else => try self.current_content.append(c),
            }
        }
        try self.current_content.appendSlice(") Tj\n");
    }

    /// Write a line of text, handling font switching between Latin and CJK
    fn writeLineSegments(self: *PdfBuilder, text: []const u8, font_size: f64, bold: bool) !void {
        const segments = try cjk.splitTextSegments(self.allocator, text);
        defer {
            for (segments) |seg| self.allocator.free(seg.text);
            self.allocator.free(segments);
        }
        for (segments) |seg| {
            if (seg.is_cjk) {
                try self.setFont(FONT_CJK, font_size);
            } else {
                const f = if (bold) FONT_HELVETICA_BOLD else FONT_HELVETICA;
                try self.setFont(f, font_size);
            }
            try self.showText(seg.text);
        }
    }

    /// Wrap a text string into multiple lines that fit within content width.
    /// Returns an array of line strings. Caller owns the returned memory.
    fn wrapText(self: *PdfBuilder, text: []const u8, font_size: f64) ![][]const u8 {
        var lines = std.array_list.Managed([]const u8).init(self.allocator);
        errdefer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit();
        }

        const max_width = self.contentWidth();
        var line_buf = std.array_list.Managed(u8).init(self.allocator);
        defer line_buf.deinit();
        var current_width: f64 = 0;

        var view = std.unicode.Utf8View.init(text) catch {
            try lines.append(try self.allocator.dupe(u8, text));
            return lines.toOwnedSlice();
        };
        var iter = view.iterator();
        var prev_i = iter.i;

        while (iter.nextCodepoint()) |cp| {
            const cur_i = iter.i;
            const char_bytes = text[prev_i..cur_i];
            const cw = cjk.charWidthPt(cp, font_size);

            if (cp == '\n') {
                try lines.append(try self.allocator.dupe(u8, line_buf.items));
                line_buf.clearRetainingCapacity();
                current_width = 0;
                prev_i = cur_i;
                continue;
            }

            if (current_width + cw > max_width and line_buf.items.len > 0) {
                // For Latin text, try to break at the last space
                if (!cjk.isCjk(cp)) {
                    if (std.mem.lastIndexOfScalar(u8, line_buf.items, ' ')) |space_pos| {
                        if (space_pos > 0) {
                            const before_space = try self.allocator.dupe(u8, line_buf.items[0..space_pos]);
                            try lines.append(before_space);
                            const after_space = line_buf.items[space_pos + 1 ..];
                            const remaining = try self.allocator.dupe(u8, after_space);
                            line_buf.clearRetainingCapacity();
                            try line_buf.appendSlice(remaining);
                            self.allocator.free(remaining);
                            current_width = cjk.measureTextWidth(line_buf.items, font_size);
                            try line_buf.appendSlice(char_bytes);
                            current_width += cw;
                            prev_i = cur_i;
                            continue;
                        }
                    }
                }
                try lines.append(try self.allocator.dupe(u8, line_buf.items));
                line_buf.clearRetainingCapacity();
                current_width = 0;
            }

            try line_buf.appendSlice(char_bytes);
            current_width += cw;
            prev_i = cur_i;
        }

        if (line_buf.items.len > 0) {
            try lines.append(try self.allocator.dupe(u8, line_buf.items));
        }

        return lines.toOwnedSlice();
    }

    /// Draw a horizontal rule
    fn drawHRule(self: *PdfBuilder) !void {
        try self.current_content.writer().print("0.7 G\n{d:.1} {d:.1} m {d:.1} {d:.1} l S\n0 G\n", .{
            self.pg.margin_left,
            self.y,
            self.pg.paper_w - self.pg.margin_right,
            self.y,
        });
        self.y -= 10;
    }

    /// Draw a filled rectangle (for code block backgrounds, etc.)
    fn drawRect(self: *PdfBuilder, x: f64, y: f64, w: f64, h: f64, r: f64, g: f64, b: f64) !void {
        try self.current_content.writer().print("{d:.3} {d:.3} {d:.3} rg\n{d:.1} {d:.1} {d:.1} {d:.1} re f\n0 0 0 rg\n", .{ r, g, b, x, y, w, h });
    }

    fn finalize(self: *PdfBuilder, writer: anytype) !void {
        if (self.page_count > 0) {
            try self.endPage();
        }

        var pdf = std.array_list.Managed(u8).init(self.allocator);
        defer pdf.deinit();

        try pdf.appendSlice("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n\n");

        const total_objects = FIXED_OBJ_COUNT + self.objects.items.len;
        var offsets = try self.allocator.alloc(usize, total_objects + 1);
        defer self.allocator.free(offsets);

        // Object 1: Catalog
        offsets[1] = pdf.items.len;
        try pdf.appendSlice("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n\n");

        // Object 2: Pages
        offsets[2] = pdf.items.len;
        try pdf.appendSlice("2 0 obj\n<< /Type /Pages /Kids [");
        for (self.page_ids.items, 0..) |pid, i| {
            if (i > 0) try pdf.append(' ');
            try pdf.writer().print("{d} 0 R", .{pid});
        }
        try pdf.writer().print("] /Count {d} >>\nendobj\n\n", .{self.page_ids.items.len});

        // Object 3: Helvetica
        offsets[3] = pdf.items.len;
        try pdf.appendSlice("3 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n\n");

        // Object 4: Helvetica-Bold
        offsets[4] = pdf.items.len;
        try pdf.appendSlice("4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>\nendobj\n\n");

        // Object 5: Helvetica-Oblique
        offsets[5] = pdf.items.len;
        try pdf.appendSlice("5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Oblique /Encoding /WinAnsiEncoding >>\nendobj\n\n");

        // Object 6: Courier (monospace)
        offsets[6] = pdf.items.len;
        try pdf.appendSlice("6 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>\nendobj\n\n");

        // Object 7: CJK Type0 font
        offsets[7] = pdf.items.len;
        try pdf.appendSlice("7 0 obj\n<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light /Encoding /Identity-H /DescendantFonts [8 0 R] /ToUnicode 9 0 R >>\nendobj\n\n");

        // Object 8: CIDFont descendant
        offsets[8] = pdf.items.len;
        try pdf.appendSlice("8 0 obj\n<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 5 >> /DW 1000 >>\nendobj\n\n");

        // Object 9: ToUnicode CMap
        offsets[9] = pdf.items.len;
        const tounicode =
            "/CIDInit /ProcSet findresource begin\n" ++
            "12 dict begin\n" ++
            "begincmap\n" ++
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" ++
            "/CMapName /Adobe-Identity-UCS def\n" ++
            "/CMapType 2 def\n" ++
            "1 begincodespacerange\n" ++
            "<0000> <FFFF>\n" ++
            "endcodespacerange\n" ++
            "1 beginbfrange\n" ++
            "<0000> <FFFF> <0000>\n" ++
            "endbfrange\n" ++
            "endcmap\n" ++
            "CMapName currentdict /CMap defineresource pop\n" ++
            "end\nend\n";
        try pdf.writer().print("9 0 obj\n<< /Length {d} >>\nstream\n{s}\nendstream\nendobj\n\n", .{ tounicode.len, tounicode });

        // Dynamic objects (pages + content streams)
        for (self.objects.items, 0..) |obj, i| {
            const obj_id = FIXED_OBJ_COUNT + i + 1;
            offsets[obj_id] = pdf.items.len;
            try pdf.writer().print("{d} 0 obj\n{s}\nendobj\n\n", .{ obj_id, obj.data });
        }

        // xref table
        const xref_pos = pdf.items.len;
        try pdf.writer().print("xref\n0 {d}\n0000000000 65535 f \n", .{total_objects + 1});
        for (1..total_objects + 1) |oid| {
            try pdf.writer().print("{d:0>10} 00000 n \n", .{offsets[oid]});
        }

        try pdf.appendSlice("trailer\n");
        try pdf.writer().print("<< /Size {d} /Root 1 0 R >>\n", .{total_objects + 1});
        try pdf.appendSlice("startxref\n");
        try pdf.writer().print("{d}\n%%EOF\n", .{xref_pos});

        try writer.writeAll(pdf.items);
    }
};

fn resolveExpr(
    resolver: ?*const Resolver,
    expr: []const u8,
) []const u8 {
    if (resolver) |r| {
        const val = r.evalExpr(expr) catch return expr;
        return val orelse expr;
    }
    return expr;
}

fn spanToText(
    allocator: std.mem.Allocator,
    span: ast.Span,
    resolver: ?*const Resolver,
) ![]const u8 {
    return switch (span) {
        .text, .bold, .italic, .code, .inline_math => |s| try allocator.dupe(u8, s),
        .link => |l| try allocator.dupe(u8, l.text),
        .expr => |e| try allocator.dupe(u8, resolveExpr(resolver, e)),
        .ref_id, .footnote => |s| try allocator.dupe(u8, s),
    };
}

pub fn render(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    resolver: ?*const Resolver,
    writer: anytype,
) !void {
    const pg = layout_mod.PageLayout.fromDoc(doc);
    var b = PdfBuilder.init(allocator, pg);
    defer b.deinit();

    try b.startPage();

    // Title page section if title exists
    if (doc.metadata) |*meta| {
        if (meta.get("title")) |title| {
            b.y -= 20;
            try b.checkPageBreak(60);
            try b.current_content.appendSlice("BT\n");
            try b.setFont(FONT_HELVETICA_BOLD, 24);
            const tw = cjk.measureTextWidth(title, 24);
            try b.moveTo(b.pg.margin_left + (b.contentWidth() - tw) / 2, b.y);
            try b.writeLineSegments(title, 24, true);
            try b.current_content.appendSlice("ET\n");
            b.y -= 30;

            if (meta.get("author")) |author| {
                try b.current_content.appendSlice("BT\n");
                try b.setFont(FONT_HELVETICA, 12);
                const aw = cjk.measureTextWidth(author, 12);
                try b.moveTo(b.pg.margin_left + (b.contentWidth() - aw) / 2, b.y);
                try b.writeLineSegments(author, 12, false);
                try b.current_content.appendSlice("ET\n");
                b.y -= 18;
            }
            if (meta.get("date")) |date| {
                try b.current_content.appendSlice("BT\n");
                try b.setFont(FONT_HELVETICA, 10);
                const dw = cjk.measureTextWidth(date, 10);
                try b.moveTo(b.pg.margin_left + (b.contentWidth() - dw) / 2, b.y);
                try b.writeLineSegments(date, 10, false);
                try b.current_content.appendSlice("ET\n");
                b.y -= 14;
            }

            try b.drawHRule();
            b.y -= 10;
        }
    }

    for (doc.content.items) |node| {
        try renderNode(allocator, &b, node, resolver);
    }

    try b.finalize(writer);
}

fn renderNode(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    node: ast.Node,
    resolver: ?*const Resolver,
) anyerror!void {
    switch (node) {
        .heading => |h| try renderHeading(allocator, b, h),
        .paragraph => |p| try renderParagraph(allocator, b, p, resolver),
        .script_block => {},
        .semantic_block => |sb| try renderSemanticBlock(allocator, b, sb, resolver),
        .list => |l| try renderList(allocator, b, l, resolver),
        .table => |t| try renderTable(allocator, b, t),
        .page_directive => |pd| {
            if (std.mem.eql(u8, pd.kind, "pagebreak")) {
                try b.endPage();
                try b.startPage();
            }
        },
        .comment => {},
    }
}

fn renderHeading(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    h: ast.Heading,
) !void {
    const font_size: f64 = switch (h.level) {
        1 => 22,
        2 => 18,
        3 => 15,
        else => 13,
    };
    const spacing_before: f64 = switch (h.level) {
        1 => 24,
        2 => 20,
        3 => 16,
        else => 12,
    };
    const spacing_after: f64 = switch (h.level) {
        1 => 14,
        2 => 10,
        else => 8,
    };

    try b.checkPageBreak(font_size + spacing_before + spacing_after);
    b.y -= spacing_before;

    const lines = try b.wrapText(h.text, font_size);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    for (lines) |line| {
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_HELVETICA_BOLD, font_size);
        try b.moveTo(b.pg.margin_left, b.y);
        try b.writeLineSegments(line, font_size, true);
        try b.current_content.appendSlice("ET\n");
        b.y -= font_size * 1.3;
    }

    // Underline for level 1/2 headings
    if (h.level <= 2) {
        try b.current_content.writer().print("{d:.1} G\n{d:.1} {d:.1} m {d:.1} {d:.1} l S\n0 G\n", .{
            if (h.level == 1) @as(f64, 0.3) else @as(f64, 0.7),
            b.pg.margin_left,
            b.y + 4,
            b.pg.paper_w - b.pg.margin_right,
            b.y + 4,
        });
    }

    b.y -= spacing_after;
}

fn renderParagraph(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    p: ast.Paragraph,
    resolver: ?*const Resolver,
) !void {
    var full_text = std.array_list.Managed(u8).init(allocator);
    defer full_text.deinit();

    const font_size: f64 = 11;
    const line_height: f64 = font_size * 1.6;

    // Collect all span text for line wrapping
    for (p.spans.items) |span| {
        const text = try spanToText(allocator, span, resolver);
        defer allocator.free(text);
        try full_text.appendSlice(text);
    }

    if (full_text.items.len == 0) return;

    const lines = try b.wrapText(full_text.items, font_size);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    try b.checkPageBreak(line_height * 2);
    b.y -= 4;

    for (lines) |line| {
        try b.checkPageBreak(line_height);
        try b.current_content.appendSlice("BT\n");
        try b.moveTo(b.pg.margin_left, b.y);
        try b.writeLineSegments(line, font_size, false);
        try b.current_content.appendSlice("ET\n");
        b.y -= line_height;
    }

    b.y -= 6;
}

fn renderSemanticBlock(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    sb: ast.SemanticBlock,
    resolver: ?*const Resolver,
) !void {
    if (std.mem.eql(u8, sb.block_type, "code")) {
        try renderCodeBlock(allocator, b, sb);
    } else if (std.mem.eql(u8, sb.block_type, "math")) {
        try renderMathBlock(allocator, b, sb);
    } else if (std.mem.eql(u8, sb.block_type, "quote")) {
        try renderQuoteBlock(allocator, b, sb);
    } else if (std.mem.eql(u8, sb.block_type, "note") or
        std.mem.eql(u8, sb.block_type, "warning") or
        std.mem.eql(u8, sb.block_type, "tip"))
    {
        try renderAdmonitionBlock(allocator, b, sb);
    } else if (std.mem.eql(u8, sb.block_type, "figure")) {
        try renderFigure(allocator, b, sb);
    } else {
        if (sb.content) |c| {
            const trimmed = std.mem.trim(u8, c, " \n\r\t");
            if (trimmed.len > 0) {
                const lines = try b.wrapText(trimmed, 11);
                defer {
                    for (lines) |line| allocator.free(line);
                    allocator.free(lines);
                }
                for (lines) |line| {
                    try b.checkPageBreak(17);
                    try b.current_content.appendSlice("BT\n");
                    try b.setFont(FONT_HELVETICA, 11);
                    try b.moveTo(b.pg.margin_left, b.y);
                    try b.writeLineSegments(line, 11, false);
                    try b.current_content.appendSlice("ET\n");
                    b.y -= 17;
                }
                b.y -= 6;
            }
        }
        for (sb.children.items) |child| {
            try renderNode(allocator, b, child, resolver);
        }
    }
}

fn renderCodeBlock(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    sb: ast.SemanticBlock,
) !void {
    const content = sb.content orelse return;
    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    if (trimmed.len == 0) return;

    const code_font_size: f64 = 9;
    const code_line_height: f64 = code_font_size * 1.5;
    const padding: f64 = 8;
    const indent: f64 = 12;

    var code_lines = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (code_lines.items) |_| {}
        code_lines.deinit();
    }

    var line_iter = std.mem.splitScalar(u8, trimmed, '\n');
    while (line_iter.next()) |line| {
        try code_lines.append(line);
    }

    const block_height = @as(f64, @floatFromInt(code_lines.items.len)) * code_line_height + padding * 2;
    try b.checkPageBreak(block_height + 20);
    b.y -= 8;

    // Background rectangle
    try b.drawRect(
        b.pg.margin_left,
        b.y - block_height + padding,
        b.contentWidth(),
        block_height,
        0.95,
        0.95,
        0.95,
    );

    // Caption (if any)
    if (sb.attrs.get("caption")) |caption| {
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_HELVETICA_OBLIQUE, 9);
        try b.moveTo(b.pg.margin_left + indent, b.y + 2);
        try b.writeLineSegments(caption, 9, false);
        try b.current_content.appendSlice("ET\n");
    }

    b.y -= padding;

    for (code_lines.items) |line| {
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_COURIER, code_font_size);
        try b.moveTo(b.pg.margin_left + indent, b.y);
        if (line.len > 0) {
            try b.showText(line);
        }
        try b.current_content.appendSlice("ET\n");
        b.y -= code_line_height;
    }

    b.y -= padding + 8;
}

fn renderMathBlock(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    sb: ast.SemanticBlock,
) !void {
    const content = sb.content orelse return;
    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    if (trimmed.len == 0) return;

    try b.checkPageBreak(30);
    b.y -= 10;

    // Centered, italic, with light background
    const tw = cjk.measureTextWidth(trimmed, 11);
    const cx = b.pg.margin_left + (b.contentWidth() - tw) / 2;

    try b.drawRect(
        b.pg.margin_left + 20,
        b.y - 6,
        b.contentWidth() - 40,
        22,
        0.97,
        0.97,
        1.0,
    );

    try b.current_content.appendSlice("BT\n");
    try b.setFont(FONT_HELVETICA_OBLIQUE, 11);
    try b.moveTo(cx, b.y);
    try b.writeLineSegments(trimmed, 11, false);
    try b.current_content.appendSlice("ET\n");
    b.y -= 24;

    _ = allocator;
}

fn renderQuoteBlock(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    sb: ast.SemanticBlock,
) !void {
    const content = sb.content orelse return;
    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    if (trimmed.len == 0) return;

    const font_size: f64 = 10.5;
    const line_height: f64 = font_size * 1.6;
    const indent: f64 = 24;

    const lines = try b.wrapText(trimmed, font_size);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    const block_height = @as(f64, @floatFromInt(lines.len)) * line_height + 16;
    try b.checkPageBreak(block_height);
    b.y -= 8;

    // Left border bar
    try b.current_content.writer().print("0.6 0.6 0.6 rg\n{d:.1} {d:.1} 3 {d:.1} re f\n0 0 0 rg\n", .{
        b.pg.margin_left + 4,
        b.y - block_height + 16,
        block_height - 8,
    });

    // Gray text color
    try b.current_content.appendSlice("0.3 0.3 0.3 rg\n");
    for (lines) |line| {
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_HELVETICA_OBLIQUE, font_size);
        try b.moveTo(b.pg.margin_left + indent, b.y);
        try b.writeLineSegments(line, font_size, false);
        try b.current_content.appendSlice("ET\n");
        b.y -= line_height;
    }

    // Attribution
    if (sb.attrs.get("source")) |source| {
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_HELVETICA, 9);
        try b.moveTo(b.pg.margin_left + indent, b.y);
        try b.showTextAscii("— ");
        try b.showText(source);
        try b.current_content.appendSlice("ET\n");
        b.y -= 14;
    }

    try b.current_content.appendSlice("0 0 0 rg\n");
    b.y -= 10;
}

fn renderAdmonitionBlock(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    sb: ast.SemanticBlock,
) !void {
    const content = sb.content orelse return;
    const trimmed = std.mem.trim(u8, content, " \n\r\t");
    if (trimmed.len == 0) return;

    const font_size: f64 = 10;
    const line_height: f64 = font_size * 1.5;
    const padding: f64 = 10;

    const lines = try b.wrapText(trimmed, font_size);
    defer {
        for (lines) |line| allocator.free(line);
        allocator.free(lines);
    }

    const block_height = @as(f64, @floatFromInt(lines.len)) * line_height + padding * 2 + 20;
    try b.checkPageBreak(block_height);
    b.y -= 8;

    // Background color based on type
    const bg = if (std.mem.eql(u8, sb.block_type, "warning"))
        .{ @as(f64, 1.0), @as(f64, 0.95), @as(f64, 0.88) }
    else if (std.mem.eql(u8, sb.block_type, "tip"))
        .{ @as(f64, 0.91), @as(f64, 0.96), @as(f64, 0.91) }
    else
        .{ @as(f64, 0.91), @as(f64, 0.95), @as(f64, 0.97) };

    try b.drawRect(
        b.pg.margin_left,
        b.y - block_height + padding * 2,
        b.contentWidth(),
        block_height,
        bg[0],
        bg[1],
        bg[2],
    );

    // Title
    const title = if (std.mem.eql(u8, sb.block_type, "warning"))
        "Warning"
    else if (std.mem.eql(u8, sb.block_type, "tip"))
        "Tip"
    else
        "Note";

    try b.current_content.appendSlice("BT\n");
    try b.setFont(FONT_HELVETICA_BOLD, 10);
    try b.moveTo(b.pg.margin_left + padding, b.y);
    try b.showTextAscii(title);
    try b.current_content.appendSlice("ET\n");
    b.y -= 16;

    for (lines) |line| {
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_HELVETICA, font_size);
        try b.moveTo(b.pg.margin_left + padding, b.y);
        try b.writeLineSegments(line, font_size, false);
        try b.current_content.appendSlice("ET\n");
        b.y -= line_height;
    }

    b.y -= padding + 6;
}

fn renderFigure(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    sb: ast.SemanticBlock,
) !void {
    _ = allocator;
    const caption = sb.attrs.get("caption") orelse "";
    if (caption.len == 0) return;

    try b.checkPageBreak(30);
    b.y -= 8;

    // Render caption centered
    const tw = cjk.measureTextWidth(caption, 10);
    try b.current_content.appendSlice("BT\n");
    try b.setFont(FONT_HELVETICA_OBLIQUE, 10);
    try b.moveTo(b.pg.margin_left + (b.contentWidth() - tw) / 2, b.y);
    try b.writeLineSegments(caption, 10, false);
    try b.current_content.appendSlice("ET\n");
    b.y -= 18;
}

fn renderList(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    l: ast.List,
    resolver: ?*const Resolver,
) !void {
    const font_size: f64 = 11;
    const line_height: f64 = font_size * 1.5;
    const bullet_indent: f64 = 16;

    try b.checkPageBreak(line_height * 2);
    b.y -= 4;

    for (l.items.items, 0..) |item, idx| {
        var text = std.array_list.Managed(u8).init(allocator);
        defer text.deinit();
        for (item.spans.items) |span| {
            const s = try spanToText(allocator, span, resolver);
            defer allocator.free(s);
            try text.appendSlice(s);
        }

        // Bullet or number prefix
        var prefix_buf: [16]u8 = undefined;
        const prefix = if (l.ordered)
            std.fmt.bufPrint(&prefix_buf, "{d}. ", .{idx + 1}) catch "- "
        else
            "\xe2\x80\xa2 "; // Unicode bullet •

        try b.checkPageBreak(line_height);
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_HELVETICA, font_size);
        try b.moveTo(b.pg.margin_left + bullet_indent, b.y);
        try b.showTextAscii(prefix);
        try b.current_content.appendSlice("ET\n");

        // Item text (wrapped, indented further)
        const saved_margin = b.pg.margin_left;
        b.pg.margin_left += bullet_indent + 12;

        const lines = try b.wrapText(text.items, font_size);
        defer {
            for (lines) |line| allocator.free(line);
            allocator.free(lines);
        }

        for (lines, 0..) |line, li| {
            if (li > 0) {
                try b.checkPageBreak(line_height);
            }
            try b.current_content.appendSlice("BT\n");
            try b.setFont(FONT_HELVETICA, font_size);
            try b.moveTo(b.pg.margin_left, b.y);
            try b.writeLineSegments(line, font_size, false);
            try b.current_content.appendSlice("ET\n");
            b.y -= line_height;
        }

        b.pg.margin_left = saved_margin;
    }

    b.y -= 6;
}

fn renderTable(
    allocator: std.mem.Allocator,
    b: *PdfBuilder,
    t: ast.Table,
) !void {
    const font_size: f64 = 10;
    const row_height: f64 = 18;
    const cell_padding: f64 = 6;
    const num_cols = t.headers.items.len;
    if (num_cols == 0) return;

    const col_width = b.contentWidth() / @as(f64, @floatFromInt(num_cols));
    const total_rows: usize = 1 + t.rows.items.len;
    const total_height = @as(f64, @floatFromInt(total_rows)) * row_height;

    try b.checkPageBreak(total_height + 20);
    b.y -= 8;

    const table_top = b.y;
    const x_start = b.pg.margin_left;

    // Header background
    try b.drawRect(x_start, table_top - row_height, b.contentWidth(), row_height, 0.92, 0.92, 0.92);

    // Header text
    for (t.headers.items, 0..) |header, ci| {
        const x = x_start + @as(f64, @floatFromInt(ci)) * col_width + cell_padding;
        try b.current_content.appendSlice("BT\n");
        try b.setFont(FONT_HELVETICA_BOLD, font_size);
        try b.moveTo(x, table_top - row_height + 5);
        try b.writeLineSegments(header, font_size, true);
        try b.current_content.appendSlice("ET\n");
    }

    // Data rows
    for (t.rows.items, 0..) |row, ri| {
        const ry = table_top - @as(f64, @floatFromInt(ri + 1)) * row_height;

        // Alternating row background
        if (ri % 2 == 1) {
            try b.drawRect(x_start, ry - row_height, b.contentWidth(), row_height, 0.97, 0.97, 0.97);
        }

        for (row.items, 0..) |cell, ci| {
            if (ci >= num_cols) break;
            const x = x_start + @as(f64, @floatFromInt(ci)) * col_width + cell_padding;
            try b.current_content.appendSlice("BT\n");
            try b.setFont(FONT_HELVETICA, font_size);
            try b.moveTo(x, ry - row_height + 5);
            try b.writeLineSegments(cell, font_size, false);
            try b.current_content.appendSlice("ET\n");
        }
    }

    // Grid lines
    try b.current_content.appendSlice("0.7 G\n0.5 w\n");
    // Horizontal lines
    for (0..total_rows + 1) |ri| {
        const ly = table_top - @as(f64, @floatFromInt(ri)) * row_height;
        try b.current_content.writer().print("{d:.1} {d:.1} m {d:.1} {d:.1} l S\n", .{
            x_start,    ly,
            x_start + b.contentWidth(), ly,
        });
    }
    // Vertical lines
    for (0..num_cols + 1) |ci| {
        const lx = x_start + @as(f64, @floatFromInt(ci)) * col_width;
        try b.current_content.writer().print("{d:.1} {d:.1} m {d:.1} {d:.1} l S\n", .{
            lx,                        table_top,
            lx, table_top - total_height,
        });
    }
    try b.current_content.appendSlice("0 G\n1 w\n");

    b.y = table_top - total_height - 12;
    _ = allocator;
}
