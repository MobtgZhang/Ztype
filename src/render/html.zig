//! Ztype HTML 渲染器
//! 将 AST 渲染为 HTML5 文档

const std = @import("std");
const ast = @import("../ast.zig");

pub fn render(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    resolver: ?*const @import("../resolver.zig").Resolver,
    writer: anytype,
) !void {
    const title = if (doc.metadata) |*m| m.get("title") orelse "Untitled" else "Untitled";
    const lang = if (doc.metadata) |*m| m.get("lang") orelse "zh" else "zh";

    try writer.writeAll("<!DOCTYPE html>\n<html lang=\"");
    try escapeHtml(writer, lang);
    try writer.writeAll("\">\n<head>\n<meta charset=\"UTF-8\">\n<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n<title>");
    try escapeHtml(writer, title);
    try writer.writeAll("</title>\n<style>\n");
    try writer.writeAll("body{font-family:\"Noto Sans CJK SC\",\"Noto Sans CJK JP\",\"Noto Sans CJK KR\",\"Microsoft YaHei\",\"SimSun\",sans-serif;line-height:1.6}\n");
    try writer.writeAll("table{border-collapse:collapse;width:100%;margin:1em 0}\n");
    try writer.writeAll("th,td{border:1px solid #ccc;padding:.5em 1em;text-align:left}\n");
    try writer.writeAll("th{background:#f5f5f5;font-weight:600}\n");
    try writer.writeAll("figure{margin:1em 0;text-align:center}\n");
    try writer.writeAll("figure img{max-width:100%;height:auto}\n");
    try writer.writeAll("figcaption{font-size:.9em;color:#666;margin-top:.5em}\n");
    try writer.writeAll(".note,.warning,.tip{padding:1em;margin:1em 0;border-radius:4px}\n");
    try writer.writeAll(".note{background:#e8f4f8}\n");
    try writer.writeAll(".warning{background:#fff3e0}\n");
    try writer.writeAll(".tip{background:#e8f5e9}\n");
    try writer.writeAll("</style>\n");
    try writer.writeAll("<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css\">\n");
    try writer.writeAll("<script src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js\"></script>\n");
    try writer.writeAll("<script src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js\"></script>\n");
    try writer.writeAll("</head>\n<body>\n<article>\n");

    for (doc.content.items) |node| {
        try renderNode(allocator, node, resolver, writer);
    }

    try writer.writeAll("<script>document.addEventListener(\"DOMContentLoaded\",function(){if(typeof renderMathInElement!==\"undefined\")renderMathInElement(document.body,{delimiters:[{left:\"\\\\[\",right:\"\\\\]\",display:true}]});});</script>\n");
    try writer.writeAll("</article>\n</body>\n</html>\n");
}

fn renderNode(
    allocator: std.mem.Allocator,
    node: ast.Node,
    resolver: ?*const @import("../resolver.zig").Resolver,
    writer: anytype,
) anyerror!void {
    switch (node) {
        .heading => |h| {
            var tag_buf: [4]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "h{d}", .{h.level}) catch "h1";
            try writer.print("<{s}", .{tag});
            if (h.id) |id| {
                try writer.writeAll(" id=\"");
                try escapeHtml(writer, id);
                try writer.writeAll("\"");
            }
            try writer.writeAll(">");
            try escapeHtml(writer, h.text);
            try writer.print("</{s}>\n", .{tag});
        },
        .paragraph => |p| {
            try writer.writeAll("<p>");
            for (p.spans.items) |span| {
                try renderSpan(span, resolver, writer);
            }
            try writer.writeAll("</p>\n");
        },
        .script_block => {
            // 脚本块不直接输出
        },
        .semantic_block => |sb| {
            try renderSemanticBlock(allocator, sb, resolver, writer);
        },
        .list => |l| {
            try writer.writeAll("<ul>\n");
            for (l.items.items) |item| {
                try writer.writeAll("<li>");
                for (item.spans.items) |span| {
                    try renderSpan(span, resolver, writer);
                }
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>\n");
        },
        .table => |t| {
            try writer.writeAll("<table>");
            if (t.caption) |cap| {
                try writer.writeAll("<caption>");
                try escapeHtml(writer, cap);
                try writer.writeAll("</caption>");
            }
            try writer.writeAll("<thead><tr>");
            for (t.headers.items) |h| {
                try writer.writeAll("<th>");
                try escapeHtml(writer, h);
                try writer.writeAll("</th>");
            }
            try writer.writeAll("</tr></thead><tbody>");
            for (t.rows.items) |row| {
                try writer.writeAll("<tr>");
                for (row.items) |cell| {
                    try writer.writeAll("<td>");
                    try escapeHtml(writer, cell);
                    try writer.writeAll("</td>");
                }
                try writer.writeAll("</tr>");
            }
            try writer.writeAll("</tbody></table>\n");
        },
        .page_directive => {
            // 页面指令在 HTML 中可忽略或转为注释
        },
        .comment => {},
    }
}

fn renderSemanticBlock(
    allocator: std.mem.Allocator,
    sb: ast.SemanticBlock,
    resolver: ?*const @import("../resolver.zig").Resolver,
    writer: anytype,
) !void {
    if (std.mem.eql(u8, sb.block_type, "figure")) {
        const src = sb.attrs.get("src") orelse "";
        const caption = sb.attrs.get("caption") orelse "";
        const width = sb.attrs.get("width") orelse "";
        try writer.writeAll("<figure");
        if (width.len > 0) {
            try writer.print(" style=\"max-width:{s}\"", .{width});
        }
        try writer.writeAll(">");
        if (src.len > 0) {
            try writer.print("<img src=\"{s}\" alt=\"\"", .{src});
            if (width.len > 0) try writer.print(" style=\"width:{s}\"", .{width});
            try writer.writeAll(" />");
        }
        if (caption.len > 0) {
            try writer.writeAll("<figcaption>");
            try escapeHtml(writer, caption);
            try writer.writeAll("</figcaption>");
        }
        try writer.writeAll("</figure>\n");
    } else if (std.mem.eql(u8, sb.block_type, "math")) {
        if (sb.content) |c| {
            const trimmed = std.mem.trim(u8, c, " \n\r\t");
            if (trimmed.len > 0) {
                try writer.writeAll("<div class=\"math-block\">\\[");
                try escapeHtml(writer, trimmed);
                try writer.writeAll("\\]</div>\n");
            }
        }
    } else if (std.mem.eql(u8, sb.block_type, "code")) {
        const lang = sb.modifier orelse "";
        try writer.writeAll("<pre><code");
        if (lang.len > 0) {
            try writer.print(" class=\"language-{s}\"", .{lang});
        }
        try writer.writeAll(">");
        if (sb.content) |c| {
            try escapeHtml(writer, c);
        }
        try writer.writeAll("</code></pre>\n");
    } else if (std.mem.eql(u8, sb.block_type, "quote")) {
        try writer.writeAll("<blockquote>");
        if (sb.content) |c| {
            try escapeHtml(writer, c);
        }
        if (sb.attrs.get("source")) |src| {
            try writer.writeAll("<cite>— ");
            try escapeHtml(writer, src);
            try writer.writeAll("</cite>");
        }
        try writer.writeAll("</blockquote>\n");
    } else if (std.mem.eql(u8, sb.block_type, "note") or
        std.mem.eql(u8, sb.block_type, "warning") or
        std.mem.eql(u8, sb.block_type, "tip"))
    {
        const cls = sb.block_type;
        try writer.print("<div class=\"{s}\">", .{cls});
        if (sb.content) |c| {
            try escapeHtml(writer, c);
        }
        try writer.writeAll("</div>\n");
    } else {
        try writer.print("<div class=\"block-{s}\">", .{sb.block_type});
        if (sb.content) |c| {
            try escapeHtml(writer, c);
        }
        for (sb.children.items) |child| {
            try renderNode(allocator, child, resolver, writer);
        }
        try writer.writeAll("</div>\n");
    }
}

fn renderSpan(
    span: ast.Span,
    resolver: ?*const @import("../resolver.zig").Resolver,
    writer: anytype,
) !void {
    switch (span) {
        .text => |s| try escapeHtml(writer, s),
        .bold => |s| {
            try writer.writeAll("<strong>");
            try escapeHtml(writer, s);
            try writer.writeAll("</strong>");
        },
        .italic => |s| {
            try writer.writeAll("<em>");
            try escapeHtml(writer, s);
            try writer.writeAll("</em>");
        },
        .code => |s| {
            try writer.writeAll("<code>");
            try escapeHtml(writer, s);
            try writer.writeAll("</code>");
        },
        .link => |l| {
            try writer.print("<a href=\"{s}\">", .{l.url});
            try escapeHtml(writer, l.text);
            try writer.writeAll("</a>");
        },
        .expr => |e| {
            if (resolver) |r| {
                const val = r.evalExpr(e) catch null;
                if (val) |v| {
                    try escapeHtml(writer, v);
                } else {
                    try writer.print("@({s})", .{e});
                }
            } else {
                try writer.print("@({s})", .{e});
            }
        },
        .ref_id => |r| {
            try writer.print("<a href=\"#{s}\">", .{r});
            try escapeHtml(writer, r);
            try writer.writeAll("</a>");
        },
        .footnote => |f| {
            try writer.writeAll("<sup title=\"");
            try escapeHtml(writer, f);
            try writer.writeAll("\">[?]</sup>");
        },
    }
}

fn escapeHtml(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(c),
        }
    }
}
