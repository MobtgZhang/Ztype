//! Ztype PDF 渲染器
//! 将 AST 渲染为 PDF 文档，支持 CJK（中日韩）Unicode

const std = @import("std");
const ast = @import("../ast.zig");
const cjk = @import("../util/cjk.zig");
const layout = @import("../util/layout.zig");

fn hasNonAscii(s: []const u8) bool {
    for (s) |c| {
        if (c >= 128) return true;
    }
    return false;
}

/// 输出 PDF 文本字符串，ASCII 用括号格式，含 CJK 时用 hex UTF-16BE
fn writePdfString(buf: *std.array_list.Managed(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    if (hasNonAscii(s)) {
        const encoded = try cjk.utf8ToPdfHex(allocator, s);
        defer allocator.free(encoded);
        try buf.appendSlice(encoded);
    } else {
        try buf.append('(');
        for (s) |c| {
            switch (c) {
                '\\' => try buf.appendSlice("\\\\"),
                '(' => try buf.appendSlice("\\("),
                ')' => try buf.appendSlice("\\)"),
                '\n' => try buf.appendSlice("\\n"),
                '\r' => try buf.appendSlice("\\r"),
                '\t' => try buf.appendSlice("\\t"),
                else => if (c >= 32 and c < 127) try buf.append(c) else try buf.append('?'),
            }
        }
        try buf.append(')');
    }
}

fn appendSpanText(
    buf: *std.array_list.Managed(u8),
    allocator: std.mem.Allocator,
    span: ast.Span,
    resolver: ?*const @import("../resolver.zig").Resolver,
) !void {
    switch (span) {
        .text, .bold, .italic, .code => |s| try writePdfString(buf, allocator, s),
        .link => |l| try writePdfString(buf, allocator, l.text),
        .expr => |e| {
            const s = blk: {
                if (resolver) |r| {
                    const val = r.evalExpr(e) catch break :blk e;
                    break :blk val orelse e;
                }
                break :blk e;
            };
            try writePdfString(buf, allocator, s);
        },
        .ref_id, .footnote => |s| try writePdfString(buf, allocator, s),
    }
}

pub fn render(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    resolver: ?*const @import("../resolver.zig").Resolver,
    writer: anytype,
) !void {
    var pdf = std.array_list.Managed(u8).init(allocator);
    defer pdf.deinit();

    try pdf.appendSlice("%PDF-1.4\n%\xe2\xe3\xcf\xd3\n\n");

    const pg = layout.PageLayout.fromDoc(doc);
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();

    var y: f64 = pg.paper_h - pg.margin_top - 20;
    const line_height: f64 = 14;
    const margin: f64 = pg.margin_left;

    // 页眉
    if (pg.header_left != null or pg.header_center != null or pg.header_right != null) {
        const header_y = pg.paper_h - pg.margin_top + 5;
        try content.appendSlice("BT\n/F1 10 Tf\n");
        if (pg.header_left) |s| {
            try content.writer().print("{d} {d} Td\n", .{ pg.margin_left, header_y });
            try writePdfString(&content, allocator, s);
            try content.appendSlice(" Tj\n");
        }
        if (pg.header_right) |s| {
            try content.writer().print("{d} {d} Td\n", .{ pg.paper_w - pg.margin_right - 100, header_y });
            try writePdfString(&content, allocator, s);
            try content.appendSlice(" Tj\n");
        }
        try content.appendSlice("ET\n");
    }

    for (doc.content.items) |node| {
        switch (node) {
            .heading => |h| {
                const size = @max(10, 24 - @as(i32, h.level) * 4);
                try content.appendSlice("BT\n");
                try content.writer().print("/F1 {d} Tf\n", .{size});
                try content.writer().print("{d} {d} Td\n", .{ margin, y });
                try writePdfString(&content, allocator, h.text);
                try content.appendSlice(" Tj\nET\n");
                y -= line_height * 1.5;
            },
            .paragraph => |p| {
                try content.appendSlice("BT\n/F1 12 Tf\n");
                try content.writer().print("{d} {d} Td\n", .{ margin, y });
                for (p.spans.items) |span| {
                    try appendSpanText(&content, allocator, span, resolver);
                    try content.appendSlice(" Tj\n");
                }
                try content.appendSlice("ET\n");
                y -= line_height;
            },
            .script_block => {},
            .semantic_block => |sb| {
                if (std.mem.eql(u8, sb.block_type, "figure")) {
                    const caption = sb.attrs.get("caption") orelse sb.attrs.get("src") orelse "";
                    if (caption.len > 0) {
                        try content.appendSlice("BT\n/F1 10 Tf\n");
                        try content.writer().print("{d} {d} Td\n", .{ margin, y });
                        try writePdfString(&content, allocator, caption);
                        try content.appendSlice(" Tj\nET\n");
                        y -= line_height;
                    }
                } else if (std.mem.eql(u8, sb.block_type, "math")) {
                    if (sb.content) |c| {
                        try content.appendSlice("BT\n/F1 10 Tf\n");
                        try content.writer().print("{d} {d} Td\n", .{ margin, y });
                        try writePdfString(&content, allocator, std.mem.trim(u8, c, " \n\r\t"));
                        try content.appendSlice(" Tj\nET\n");
                        y -= line_height;
                    }
                } else if (sb.content) |c| {
                    try content.appendSlice("BT\n/F1 10 Tf\n");
                    try content.writer().print("{d} {d} Td\n", .{ margin, y });
                    try writePdfString(&content, allocator, c);
                    try content.appendSlice(" Tj\nET\n");
                    y -= line_height;
                }
            },
            .list => |l| {
                for (l.items.items) |item| {
                    try content.appendSlice("BT\n/F1 12 Tf\n");
                    try content.writer().print("{d} {d} Td\n", .{ margin, y });
                    try content.appendSlice("(- ) Tj\n");
                    for (item.spans.items) |span| {
                        try appendSpanText(&content, allocator, span, resolver);
                        try content.appendSlice(" Tj\n");
                    }
                    try content.appendSlice("ET\n");
                    y -= line_height;
                }
            },
            .table => |t| {
                for (t.headers.items) |h| {
                    try content.appendSlice("BT\n/F1 10 Tf\n");
                    try content.writer().print("{d} {d} Td\n", .{ margin, y });
                    try writePdfString(&content, allocator, h);
                    try content.appendSlice(" Tj\nET\n");
                    y -= line_height;
                }
                for (t.rows.items) |row| {
                    for (row.items) |cell| {
                        try content.appendSlice("BT\n/F1 10 Tf\n");
                        try content.writer().print("{d} {d} Td\n", .{ margin, y });
                        try writePdfString(&content, allocator, cell);
                        try content.appendSlice(" Tj\nET\n");
                        y -= line_height;
                    }
                }
            },
            .page_directive, .comment => {},
        }
    }

    const obj1 = pdf.items.len;
    try pdf.appendSlice("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n\n");

    const obj2 = pdf.items.len;
    try pdf.appendSlice("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n\n");

    const obj3 = pdf.items.len;
    try pdf.writer().print("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {d} {d}] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n\n", .{ pg.paper_w, pg.paper_h });

    const obj4 = pdf.items.len;
    try pdf.appendSlice("4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n\n");

    const obj5 = pdf.items.len;
    try pdf.writer().print("5 0 obj\n<< /Length {d} >>\nstream\n", .{content.items.len});
    try pdf.appendSlice(content.items);
    try pdf.appendSlice("\nendstream\nendobj\n\n");

    const xref_pos = pdf.items.len;
    try pdf.writer().print("xref\n0 6\n0000000000 65535 f \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n{d:0>10} 00000 n \n", .{ obj1, obj2, obj3, obj4, obj5 });
    try pdf.appendSlice("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n");
    try pdf.writer().print("{d}\n%%EOF\n", .{xref_pos});

    try writer.writeAll(pdf.items);
}
