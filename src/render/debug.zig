//! Ztype 调试输出渲染器
//! 打印元数据、风格、AST、分页结果、目录与交叉引用，便于排查排版问题。

const std = @import("std");
const ast = @import("../ast.zig");
const engine = @import("../engine.zig");
const math = @import("../math.zig");
const fonts = @import("../fonts.zig");
const style = @import("../style.zig");

pub fn render(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    eng: *engine.Engine,
    pages: []const engine.Page,
    writer: anytype,
) !void {
    _ = allocator;

    try writer.writeAll("=== METADATA ===\n");
    var iter = doc.metadata.values.iterator();
    while (iter.next()) |entry| {
        try writer.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    try writer.writeAll("\n=== STYLE ===\n");
    try writeStyle(eng.style, writer);

    try writer.writeAll("\n=== AST ===\n");
    for (doc.content) |block| try renderBlock(eng, block, writer, 0);

    try writer.writeAll("\n=== PAGES ===\n");
    for (pages, 1..) |page, i| {
        try writer.print("page {d}  {d:.2} x {d:.2} pt  margins T{d:.1} R{d:.1} B{d:.1} L{d:.1}\n", .{
            i, page.width, page.height, page.margins.top, page.margins.right, page.margins.bottom, page.margins.left,
        });
        try writer.print("  backgrounds: {d}\n", .{page.backgrounds.items.len});
        for (page.backgrounds.items) |r| try renderRect(r, writer, 4);
        try writer.print("  header: {d}\n", .{page.header.items.len});
        for (page.header.items) |it| try renderItem(it, writer, 4);
        try writer.print("  body: {d}\n", .{page.items.items.len});
        for (page.items.items) |it| try renderItem(it, writer, 4);
        try writer.print("  footer: {d}\n", .{page.footer.items.len});
        for (page.footer.items) |it| try renderItem(it, writer, 4);
        if (page.footnotes.items.len > 0) {
            try writer.print("  footnotes: {d}\n", .{page.footnotes.items.len});
            for (page.footnotes.items) |f| {
                try writer.print("    [{s}] {s}\n", .{ f.label, f.text });
            }
        }
        if (page.bookmarks.items.len > 0) {
            try writer.print("  bookmarks: {d}\n", .{page.bookmarks.items.len});
            for (page.bookmarks.items) |b| {
                try writer.print("    {d} {s} -> page {d}\n", .{ b.level, b.title, b.page });
            }
        }
    }

    if (eng.toc.items.len > 0) {
        try writer.writeAll("\n=== TOC ===\n");
        for (eng.toc.items) |entry| {
            try indent(writer, 2);
            if (entry.number) |n| try writer.print("{s} ", .{n});
            try writer.print("{s} -> page {d}\n", .{ entry.text, entry.page });
        }
    }

    if (eng.refs.count() > 0) {
        try writer.writeAll("\n=== REFERENCES ===\n");
        var ref_iter = eng.refs.iterator();
        while (ref_iter.next()) |entry| {
            try writer.print("  {s} -> {s} (page {d})\n", .{ entry.key_ptr.*, entry.value_ptr.number, entry.value_ptr.page });
        }
    }

    if (eng.footnotes.items.len > 0) {
        try writer.writeAll("\n=== FOOTNOTES ===\n");
        for (eng.footnotes.items, 1..) |f, i| {
            try writer.print("  {d} [{s}] {s} (page {d})\n", .{ i, f.label, f.text, f.page });
        }
    }
}

fn writeStyle(st: style.Style, writer: anytype) !void {
    try writer.print("  paper: {s} ({d:.2} x {d:.2} pt)\n", .{ st.paper.name, st.paper.width, st.paper.height });
    try writer.print("  margins: T{d:.1} R{d:.1} B{d:.1} L{d:.1} pt\n", .{ st.margins.top, st.margins.right, st.margins.bottom, st.margins.left });
    try writer.print("  font: {s} {d:.1}pt / leading {d:.1}pt\n", .{ @tagName(st.family), st.size, st.leading });
    try writer.print("  heading font: {s}\n", .{@tagName(st.heading_family)});
    try writer.print("  measure: {d:.1} pt\n", .{st.contentWidth()});
    try writer.print("  parskip: {d:.1}  indent: {d:.1}  justify: {s}  numbering: {s}\n", .{
        st.parskip, st.indent, if (st.justify) "true" else "false", if (st.numbering) "true" else "false",
    });
    try writer.print("  colors: text {s} muted {s} accent {s}\n", .{ colorText(st.text_color), colorText(st.muted_color), colorText(st.accent_color) });
}

fn colorText(c: style.Color) []const u8 {
    return std.fmt.allocPrint(
        std.heap.page_allocator,
        "#{x:0>2}{x:0>2}{x:0>2}",
        .{
            @as(u8, @intFromFloat(@round(c.r * 255))),
            @as(u8, @intFromFloat(@round(c.g * 255))),
            @as(u8, @intFromFloat(@round(c.b * 255))),
        },
    ) catch "#000000";
}

fn indent(writer: anytype, n: usize) !void {
    for (0..n) |_| try writer.writeAll("  ");
}

fn renderBlock(eng: *engine.Engine, block: ast.Block, writer: anytype, depth: usize) !void {
    try indent(writer, depth);
    switch (block) {
        .heading => |h| {
            try writer.print("[heading {d}]", .{h.level});
            if (h.number) |n| try writer.print(" {s}", .{n});
            if (h.id) |id| try writer.print(" id={s}", .{id});
            try writer.writeAll(" ");
            try writeInlines(eng, h.text, writer);
            try writer.writeAll("\n");
        },
        .paragraph => |p| {
            try writer.writeAll("[paragraph]\n");
            try indent(writer, depth + 1);
            try writeInlines(eng, p.content, writer);
            try writer.writeAll("\n");
        },
        .list => |l| {
            try writer.print("[list {s}]\n", .{if (l.ordered) "ordered" else "unordered"});
            for (l.items) |item| {
                try indent(writer, depth + 1);
                try writer.writeAll("- ");
                try writeInlines(eng, item.content, writer);
                try writer.writeAll("\n");
                for (item.children) |child| {
                    try indent(writer, depth + 2);
                    try writer.writeAll("- ");
                    try writeInlines(eng, child.content, writer);
                    try writer.writeAll("\n");
                }
            }
        },
        .quote => |qt| {
            try writer.writeAll("[quote]");
            if (qt.source) |s| try writer.print(" source={s}", .{s});
            if (qt.caption) |c| try writer.print(" caption={s}", .{c});
            if (qt.id) |id| try writer.print(" id={s}", .{id});
            try writer.writeAll("\n");
            for (qt.content) |child| try renderBlock(eng, child, writer, depth + 1);
        },
        .code => |c| {
            try writer.writeAll("[code]");
            if (c.language) |lang| try writer.print(" lang={s}", .{lang});
            if (c.number) |n| try writer.print(" #{s}", .{n});
            if (c.id) |id| try writer.print(" id={s}", .{id});
            try writer.writeAll("\n");
            var lines = std.mem.splitScalar(u8, c.source, '\n');
            while (lines.next()) |line| {
                try indent(writer, depth + 1);
                try writer.print("{s}\n", .{line});
            }
        },
        .figure => |f| {
            try writer.writeAll("[figure]");
            if (f.number) |n| try writer.print(" #{s}", .{n});
            if (f.src) |s| try writer.print(" src={s}", .{s});
            if (f.width) |w| try writer.print(" width={d:.1}", .{w});
            if (f.id) |id| try writer.print(" id={s}", .{id});
            if (f.caption) |c| try writer.print(" caption={s}", .{c});
            try writer.writeAll("\n");
        },
        .table => |t| {
            try writer.writeAll("[table]");
            if (t.number) |n| try writer.print(" #{s}", .{n});
            if (t.caption) |c| try writer.print(" caption={s}", .{c});
            try writer.writeAll("\n");
            try indent(writer, depth + 1);
            try writer.writeAll("headers: ");
            for (t.headers, 0..) |cell, i| {
                if (i > 0) try writer.writeAll(" | ");
                try writeInlines(eng, cell, writer);
            }
            try writer.writeAll("\n");
            for (t.rows) |row| {
                try indent(writer, depth + 1);
                try writer.writeAll("row: ");
                for (row, 0..) |cell, i| {
                    if (i > 0) try writer.writeAll(" | ");
                    try writeInlines(eng, cell, writer);
                }
                try writer.writeAll("\n");
            }
        },
        .callout => |c| {
            try writer.print("[callout {s}]", .{@tagName(c.kind)});
            if (c.title) |t| try writer.print(" title={s}", .{t});
            try writer.writeAll("\n");
            for (c.content) |child| try renderBlock(eng, child, writer, depth + 1);
        },
        .math => |m| {
            try writer.writeAll("[math]");
            if (m.number) |n| try writer.print(" #{s}", .{n});
            if (m.id) |id| try writer.print(" id={s}", .{id});
            try writer.print(" {s}\n", .{m.source});
            for (m.nodes) |node| try renderMathNode(&node, writer, depth + 1);
        },
        .definition_list => |d| {
            try writer.writeAll("[definitions]\n");
            for (d.entries) |e| {
                try indent(writer, depth + 1);
                try writeInlines(eng, e.term, writer);
                try writer.writeAll(": ");
                try writeInlines(eng, e.definition, writer);
                try writer.writeAll("\n");
            }
        },
        .bibliography => |b| {
            try writer.writeAll("[bibliography]");
            if (b.title) |t| try writer.print(" title={s}", .{t});
            try writer.writeAll("\n");
            for (b.entries, 1..) |e, i| {
                try indent(writer, depth + 1);
                try writer.print("[{d}] ", .{i});
                try writeInlines(eng, e.text, writer);
                try writer.writeAll("\n");
            }
        },
        .page_break => {
            try writer.writeAll("[pagebreak]\n");
        },
        .column_break => {
            try writer.writeAll("[columnbreak]\n");
        },
        .rule => {
            try writer.writeAll("[rule]\n");
        },
        .toc => {
            try writer.writeAll("[toc]\n");
        },
        .script => |s| {
            try writer.print("[script] {s}\n", .{s.source});
        },
    }
}

fn writeInlines(eng: *engine.Engine, inlines: []const ast.Inline, writer: anytype) !void {
    for (inlines) |node| {
        switch (node) {
            .text => |s| try writer.print("{s}", .{s}),
            .strong => |c| {
                try writer.writeAll("*");
                try writeInlines(eng, c, writer);
                try writer.writeAll("*");
            },
            .em => |c| {
                try writer.writeAll("_");
                try writeInlines(eng, c, writer);
                try writer.writeAll("_");
            },
            .code => |s| try writer.print("`{s}`", .{s}),
            .link => |l| {
                try writer.writeAll("[");
                try writeInlines(eng, l.text, writer);
                try writer.print("]({s})", .{l.url});
            },
            .ref => |r| try writer.print("[->{s}]", .{r}),
            .footnote => |c| {
                try writer.writeAll("[^");
                try writeInlines(eng, c, writer);
                try writer.writeAll("]");
            },
            .math => |nodes| {
                try writer.writeAll("$");
                for (nodes) |mn| try writeMathInline(&mn, writer);
                try writer.writeAll("$");
            },
            .expr => |e| try writer.print("@({s})", .{e}),
            .cite => |c| try writer.print("[@{s}]", .{c}),
            .sup => |c| {
                try writer.writeAll("^");
                try writeInlines(eng, c, writer);
                try writer.writeAll("^");
            },
            .sub => |c| {
                try writer.writeAll("~");
                try writeInlines(eng, c, writer);
                try writer.writeAll("~");
            },
        }
    }
}

fn writeMathInline(node: *const math.Node, writer: anytype) !void {
    switch (node.*) {
        .glyph => |g| try writer.print("{u}", .{g.cp}),
        .text => |s| try writer.writeAll(s),
        .row => |r| for (r) |n| try writeMathInline(&n, writer),
        .tag => |t| try writeMathInline(t.body, writer),
        .over_under => |o| {
            try writer.writeAll(if (o.above) "overset(" else "underset(");
            try writeMathInline(o.mark, writer);
            try writer.writeAll(",");
            try writeMathInline(o.base, writer);
            try writer.writeAll(")");
        },
        .frac => |f| {
            try writer.writeAll("frac(");
            try writeMathInline(f.num, writer);
            try writer.writeAll(",");
            try writeMathInline(f.denom, writer);
            try writer.writeAll(")");
        },
        .sqrt => |s| {
            try writer.writeAll("sqrt(");
            try writeMathInline(s.body, writer);
            try writer.writeAll(")");
        },
        .script => |s| {
            try writeMathInline(s.base, writer);
            if (s.sub) |sub| {
                try writer.writeAll("_(");
                try writeMathInline(sub, writer);
                try writer.writeAll(")");
            }
            if (s.sup) |sup| {
                try writer.writeAll("^(");
                try writeMathInline(sup, writer);
                try writer.writeAll(")");
            }
        },
        .accent => |a| try writer.print("accent({u})", .{a.cp}),
        .delim => |d| {
            try writer.print("delim({u}", .{d.left});
            try writeMathInline(d.body, writer);
            try writer.print("{u})", .{d.right});
        },
        .matrix => |m| try writer.print("matrix({d} rows)", .{m.rows.len}),
        .cases => |c| try writer.print("cases({d})", .{c.rows.len}),
        .stack => |s| try writer.print("stack({d})", .{s.items.len}),
        .binom => try writer.writeAll("binom"),
        .space => |w| try writer.print("space({d:.2})", .{w}),
        .rule => |r| try writer.print("rule({d:.2})", .{r.length}),
        .op => |o| try writer.print("op({s})", .{o.name}),
        .style => |s| try writer.print("style({s})", .{@tagName(s.font)}),
    }
}

fn renderMathNode(node: *const math.Node, writer: anytype, depth: usize) !void {
    try indent(writer, depth);
    switch (node.*) {
        .glyph => |g| try writer.print("glyph {u} class={s} style={s}\n", .{ g.cp, @tagName(g.class), @tagName(g.style) }),
        .text => |s| try writer.print("text \"{s}\"\n", .{s}),
        .row => |r| {
            try writer.print("row ({d})\n", .{r.len});
            for (r) |n| try renderMathNode(&n, writer, depth + 1);
        },
        .tag => |t| {
            try writer.print("tag{s}\n", .{if (t.suppress) " (suppress)" else ""});
            try indent(writer, depth + 1);
            try writeMathInline(t.body, writer);
            try writer.writeAll("\n");
        },
        .over_under => |o| {
            try writer.print("over_under {s}\n", .{if (o.above) "above" else "below"});
            try indent(writer, depth + 1);
            try writer.writeAll("mark: ");
            try writeMathInline(o.mark, writer);
            try writer.writeAll("\n");
            try indent(writer, depth + 1);
            try writer.writeAll("base: ");
            try writeMathInline(o.base, writer);
            try writer.writeAll("\n");
        },
        .frac => |f| {
            try writer.print("frac display={s}\n", .{if (f.display) "true" else "false"});
            try indent(writer, depth + 1);
            try writer.writeAll("num: ");
            try writeMathInline(f.num, writer);
            try writer.writeAll("\n");
            try indent(writer, depth + 1);
            try writer.writeAll("denom: ");
            try writeMathInline(f.denom, writer);
            try writer.writeAll("\n");
        },
        .sqrt => |s| {
            try writer.writeAll("sqrt\n");
            try indent(writer, depth + 1);
            try writer.writeAll("body: ");
            try writeMathInline(s.body, writer);
            try writer.writeAll("\n");
            if (s.index) |idx| {
                try indent(writer, depth + 1);
                try writer.writeAll("index: ");
                try writeMathInline(idx, writer);
                try writer.writeAll("\n");
            }
        },
        .script => |s| {
            try writer.print("script limits={s}\n", .{if (s.limits) "true" else "false"});
            try indent(writer, depth + 1);
            try writer.writeAll("base: ");
            try writeMathInline(s.base, writer);
            try writer.writeAll("\n");
            if (s.sub) |b| {
                try indent(writer, depth + 1);
                try writer.writeAll("sub: ");
                try writeMathInline(b, writer);
                try writer.writeAll("\n");
            }
            if (s.sup) |b| {
                try indent(writer, depth + 1);
                try writer.writeAll("sup: ");
                try writeMathInline(b, writer);
                try writer.writeAll("\n");
            }
        },
        .accent => |a| {
            try writer.print("accent {u} ", .{a.cp});
            try writeMathInline(a.base, writer);
            try writer.writeAll("\n");
        },
        .delim => |d| try writer.print("delim {u}..{u} stretchy={s}\n", .{ d.left, d.right, if (d.stretchy) "true" else "false" }),
        .matrix => |m| try writer.print("matrix {u}..{u} rows={d}\n", .{ m.left, m.right, m.rows.len }),
        .cases => |c| try writer.print("cases rows={d}\n", .{c.rows.len}),
        .stack => |s| try writer.print("stack items={d} align={s}\n", .{ s.items.len, @tagName(s.alignment) }),
        .binom => |b| {
            try writer.writeAll("binom\n");
            try indent(writer, depth + 1);
            try writer.writeAll("top: ");
            try writeMathInline(b.top, writer);
            try writer.writeAll("\n");
            try indent(writer, depth + 1);
            try writer.writeAll("bottom: ");
            try writeMathInline(b.bottom, writer);
            try writer.writeAll("\n");
        },
        .space => |w| try writer.print("space {d:.2}\n", .{w}),
        .rule => |r| try writer.print("rule thickness={d:.2} length={d:.2}\n", .{ r.thickness, r.length }),
        .op => |o| try writer.print("op {s}\n", .{o.name}),
        .style => |s| try writer.print("style {s} size={d:.1}\n", .{ @tagName(s.font), s.size }),
    }
}

fn renderRect(r: engine.RectItem, writer: anytype, depth: usize) !void {
    try indent(writer, depth);
    try writer.print("rect x={d:.1} y={d:.1} w={d:.1} h={d:.1}", .{ r.x, r.y, r.w, r.h });
    if (r.fill) |c| try writer.print(" fill={s}", .{colorText(c)});
    if (r.stroke) |c| try writer.print(" stroke={s}", .{colorText(c)});
    try writer.writeAll("\n");
}

fn renderItem(item: engine.Item, writer: anytype, depth: usize) !void {
    try indent(writer, depth);
    switch (item) {
        .text => |t| {
            try writer.print("text \"{s}\" font={s} size={d:.1} x={d:.1} y={d:.1}", .{ t.text, @tagName(t.font), t.size, t.x, t.y });
            if (t.scale_x != 1.0 or t.scale_y != 1.0) try writer.print(" scale={d:.2}x{d:.2}", .{ t.scale_x, t.scale_y });
            try writer.print(" color={s}", .{colorText(t.color)});
            if (t.link) |l| try writer.print(" link={s}", .{l});
            try writer.writeAll("\n");
        },
        .rule => |r| try writer.print("rule x={d:.1} y={d:.1} w={d:.1} t={d:.2}\n", .{ r.x, r.y, r.w, r.thickness }),
        .rect => |r| try renderRect(r, writer, depth),
        .image => |i| try writer.print("image {s} x={d:.1} y={d:.1} w={d:.1} h={d:.1}\n", .{ i.src, i.x, i.y, i.w, i.h }),
    }
}
