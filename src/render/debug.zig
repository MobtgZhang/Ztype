//! Ztype 调试输出渲染器
//! 将 AST 渲染为纯文本，便于调试

const std = @import("std");
const ast = @import("../ast.zig");

pub fn render(_: std.mem.Allocator, doc: *const ast.Document, writer: anytype) !void {
    if (doc.metadata) |*meta| {
        try writer.writeAll("--- METADATA ---\n");
        var iter = meta.pairs.iterator();
        while (iter.next()) |entry| {
            try writer.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try writer.writeAll("--- END METADATA ---\n\n");
    }

    for (doc.content.items) |node| {
        try renderNode(node, writer, 0);
    }
}

fn renderNode(node: ast.Node, writer: anytype, indent: usize) !void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        try writer.writeAll("  ");
    }
    switch (node) {
        .heading => |h| {
            var j: u8 = 0;
            while (j < h.level) : (j += 1) {
                try writer.writeAll("=");
            }
            try writer.writeAll(" ");
            try writer.writeAll(h.text);
            try writer.writeAll("\n");
            if (h.id) |id| {
                i = 0;
                while (i < indent) : (i += 1) try writer.writeAll("  ");
                try writer.print("#id: {s}\n", .{id});
            }
        },
        .paragraph => |p| {
            var ii: usize = 0;
            while (ii < indent) : (ii += 1) try writer.writeAll("  ");
            try writer.writeAll("[paragraph]\n");
            for (p.spans.items) |span| {
                try renderSpan(span, writer, indent + 1);
            }
        },
        .script_block => |s| {
            var ii: usize = 0;
            while (ii < indent) : (ii += 1) try writer.writeAll("  ");
            try writer.writeAll("[script]\n");
            var iii: usize = 0;
            while (iii <= indent) : (iii += 1) try writer.writeAll("  ");
            try writer.print("{s}\n", .{s.source});
        },
        .semantic_block => |sb| {
            var ii: usize = 0;
            while (ii < indent) : (ii += 1) try writer.writeAll("  ");
            try writer.print("[block::{s}", .{sb.block_type});
            if (sb.modifier) |m| {
                try writer.print(" {s}", .{m});
            }
            try writer.writeAll("]\n");
            var iter = sb.attrs.iterator();
            while (iter.next()) |e| {
                var iv: usize = 0;
                while (iv <= indent) : (iv += 1) try writer.writeAll("  ");
                try writer.print("{s}: {s}\n", .{ e.key_ptr.*, e.value_ptr.* });
            }
            if (sb.content) |c| {
                var iv: usize = 0;
                while (iv <= indent) : (iv += 1) try writer.writeAll("  ");
                try writer.print("---\n", .{});
                iv = 0;
                while (iv <= indent) : (iv += 1) try writer.writeAll("  ");
                try writer.print("{s}\n", .{c});
            }
            for (sb.children.items) |child| {
                try renderNode(child, writer, indent + 1);
            }
        },
        .list => |l| {
            var ii: usize = 0;
            while (ii < indent) : (ii += 1) try writer.writeAll("  ");
            try writer.writeAll("[list]\n");
            for (l.items.items) |item| {
                for (item.spans.items) |span| {
                    var iv: usize = 0;
                    while (iv <= indent) : (iv += 1) try writer.writeAll("  ");
                    try writer.writeAll("- ");
                    try renderSpan(span, writer, 0);
                }
            }
        },
        .table => |t| {
            var ii: usize = 0;
            while (ii < indent) : (ii += 1) try writer.writeAll("  ");
            try writer.writeAll("[table]\n");
            for (t.headers.items) |h| {
                ii = 0;
                while (ii <= indent) : (ii += 1) try writer.writeAll("  ");
                try writer.print("| {s}", .{h});
            }
            try writer.writeAll(" |\n");
            for (t.rows.items) |row| {
                ii = 0;
                while (ii <= indent) : (ii += 1) try writer.writeAll("  ");
                try writer.writeAll("| ");
                for (row.items) |cell| {
                    try writer.print("{s} | ", .{cell});
                }
                try writer.writeAll("\n");
            }
        },
        .page_directive => |pd| {
            var ii: usize = 0;
            while (ii < indent) : (ii += 1) try writer.writeAll("  ");
            try writer.print("[%% {s} {s}]\n", .{ pd.kind, pd.args });
        },
        .comment => |c| {
            var ii: usize = 0;
            while (ii < indent) : (ii += 1) try writer.writeAll("  ");
            try writer.print("; {s}\n", .{c.content});
        },
    }
}

fn renderSpan(span: ast.Span, writer: anytype, indent: usize) !void {
    _ = indent;
    switch (span) {
        .text => |s| try writer.print("  text: {s}\n", .{s}),
        .bold => |s| try writer.print("  *{s}*\n", .{s}),
        .italic => |s| try writer.print("  /{s}/\n", .{s}),
        .code => |s| try writer.print("  `{s}`\n", .{s}),
        .link => |l| try writer.print("  [{s} -> {s}]\n", .{ l.text, l.url }),
        .expr => |e| try writer.print("  @({s})\n", .{e}),
        .ref_id => |r| try writer.print("  [-> {s}]\n", .{r}),
        .footnote => |f| try writer.print("  [^ {s}]\n", .{f}),
        .inline_math => |m| try writer.print("  ${s}$\n", .{m}),
    }
}
