//! Ztype Word 渲染器
//! 将 AST 渲染为 RTF 格式（可被 Word 打开）
//! 支持 CJK（中日韩）Unicode 字符

const std = @import("std");
const ast = @import("../ast.zig");
const cjk = @import("../util/cjk.zig");
const layout = @import("../util/layout.zig");

fn escapeRtfWithAlloc(allocator: std.mem.Allocator, writer: anytype, s: []const u8) !void {
    const encoded = cjk.utf8ToRtf(allocator, s) catch {
        // 回退：逐字节转义
        for (s) |c| {
            switch (c) {
                '\\' => try writer.writeAll("\\\\"),
                '{' => try writer.writeAll("\\{"),
                '}' => try writer.writeAll("\\}"),
                '\n' => try writer.writeAll("\\par\n"),
                '\r' => {},
                '\t' => try writer.writeAll("\\tab "),
                else => if (c >= 32 and c < 127) try writer.writeByte(c) else try writer.writeByte('?'),
            }
        }
        return;
    };
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

fn renderSpanRtf(
    allocator: std.mem.Allocator,
    span: ast.Span,
    resolver: ?*const @import("../resolver.zig").Resolver,
    writer: anytype,
) !void {
    switch (span) {
        .text => |s| try escapeRtfWithAlloc(allocator, writer, s),
        .bold => |s| {
            try writer.writeAll("\\b ");
            try escapeRtfWithAlloc(allocator, writer, s);
            try writer.writeAll("\\b0 ");
        },
        .italic => |s| {
            try writer.writeAll("\\i ");
            try escapeRtfWithAlloc(allocator, writer, s);
            try writer.writeAll("\\i0 ");
        },
        .code => |s| {
            try writer.writeAll("\\f1 ");
            try escapeRtfWithAlloc(allocator, writer, s);
            try writer.writeAll("\\f0 ");
        },
        .link => |l| {
            try writer.print("{{\\field{{\\*\\fldinst HYPERLINK \"{s}\"}}{{\\fldrslt ", .{l.url});
            try escapeRtfWithAlloc(allocator, writer, l.text);
            try writer.writeAll("}}}");
        },
        .expr => |e| {
            const s = blk: {
                if (resolver) |r| {
                    const val = r.evalExpr(e) catch break :blk e;
                    break :blk val orelse e;
                }
                break :blk e;
            };
            try escapeRtfWithAlloc(allocator, writer, s);
        },
        .ref_id, .footnote => |s| try escapeRtfWithAlloc(allocator, writer, s),
    }
}

pub fn render(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    resolver: ?*const @import("../resolver.zig").Resolver,
    writer: anytype,
) !void {
    try writer.writeAll("{\\rtf1\\ansi\\uc1\\deff0\n");

    const pg = layout.PageLayout.fromDoc(doc);
    const twips_per_pt: i32 = 20;
    try writer.print("\\paperw{d}\\paperh{d}\\margl{d}\\margr{d}\\margt{d}\\margb{d}\n", .{
        @as(i32, @intFromFloat(pg.paper_w * twips_per_pt)),
        @as(i32, @intFromFloat(pg.paper_h * twips_per_pt)),
        @as(i32, @intFromFloat(pg.margin_left * twips_per_pt)),
        @as(i32, @intFromFloat(pg.margin_right * twips_per_pt)),
        @as(i32, @intFromFloat(pg.margin_top * twips_per_pt)),
        @as(i32, @intFromFloat(pg.margin_bottom * twips_per_pt)),
    });

    const title = if (doc.metadata) |*m| m.get("title") orelse "Untitled" else "Untitled";
    try writer.writeAll("{\\info{\\title ");
    try escapeRtfWithAlloc(allocator, writer, title);
    try writer.writeAll("}}\n");

    for (doc.content.items) |node| {
        switch (node) {
            .heading => |h| {
                const size = @max(14, 36 - @as(i32, h.level) * 6);
                try writer.print("\\pard\\sb100\\sa100\\b\\fs{d} ", .{size});
                try escapeRtfWithAlloc(allocator, writer, h.text);
                try writer.writeAll("\\par\n\\b0\\fs24 ");
            },
            .paragraph => |p| {
                try writer.writeAll("\\pard ");
                for (p.spans.items) |span| {
                    try renderSpanRtf(allocator, span, resolver, writer);
                }
                try writer.writeAll("\\par\n");
            },
            .script_block => {},
            .semantic_block => |sb| {
                if (sb.content) |c| {
                    try writer.writeAll("\\pard\\fi360 ");
                    try escapeRtfWithAlloc(allocator, writer, c);
                    try writer.writeAll("\\par\n");
                }
            },
            .list => |l| {
                for (l.items.items) |item| {
                    try writer.writeAll("\\pard\\li360 ");
                    try writer.writeAll("\\bullet ");
                    for (item.spans.items) |span| {
                        try renderSpanRtf(allocator, span, resolver, writer);
                    }
                    try writer.writeAll("\\par\n");
                }
            },
            .table => |t| {
                for (t.headers.items) |h| {
                    try writer.writeAll("\\pard\\b ");
                    try escapeRtfWithAlloc(allocator, writer, h);
                    try writer.writeAll("\\b0\\tab ");
                }
                try writer.writeAll("\\par\n");
                for (t.rows.items) |row| {
                    for (row.items) |cell| {
                        try escapeRtfWithAlloc(allocator, writer, cell);
                        try writer.writeAll("\\tab ");
                    }
                    try writer.writeAll("\\par\n");
                }
            },
            .page_directive, .comment => {},
        }
    }

    try writer.writeAll("}\n");
}
