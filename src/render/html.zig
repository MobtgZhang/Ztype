//! Ztype HTML 渲染器
//! 输出自包含的 HTML5：现代排版 CSS + 原生 MathML（不依赖任何 CDN）。

const std = @import("std");
const ast = @import("../ast.zig");
const style = @import("../style.zig");
const fonts = @import("../fonts.zig");
const math = @import("../math.zig");
const Resolver = @import("../resolver.zig").Resolver;

const Ctx = struct {
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    st: style.Style,
    resolver: ?*const Resolver,
    footnotes: []const []const u8 = &.{},
    /// 引文编号：按正文中首次出现的顺序编号，未被引用的条目按文献块顺序补号
    citations: std.StringHashMap(usize) = std.StringHashMap(usize).init(std.heap.page_allocator),
    counter: usize = 0,
};

pub fn render(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    st: style.Style,
    resolver: ?*const Resolver,
    writer: anytype,
) !void {
    const title = doc.metadata.getOr("title", "Untitled");
    const lang = doc.metadata.getOr("lang", "en");

    try writer.writeAll("<!DOCTYPE html>\n<html lang=\"");
    try escape(writer, lang);
    try writer.writeAll("\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
    try escape(writer, title);
    try writer.writeAll("</title>\n<style>\n");
    try writeCss(writer, st);
    try writer.writeAll("</style>\n</head>\n<body>\n<article class=\"doc\">\n");

    var ctx = Ctx{ .allocator = allocator, .doc = doc, .st = st, .resolver = resolver };
    ctx.footnotes = try collectAllFootnotes(&ctx);
    buildCitations(&ctx);

    if (doc.metadata.get("title") != null) {
        try writer.writeAll("<header class=\"frontmatter\">\n<h1 class=\"doctitle\">");
        try escape(writer, title);
        try writer.writeAll("</h1>\n");
        const author = doc.metadata.get("author");
        const date = doc.metadata.get("date");
        if (author != null or date != null) {
            try writer.writeAll("<p class=\"byline\">");
            if (author) |a| {
                try escape(writer, a);
            }
            if (date) |d| {
                if (author != null) try writer.writeAll(" · ");
                try escape(writer, d);
            }
            try writer.writeAll("</p>\n");
        }
        try writer.writeAll("</header>\n");
    }

    if (st.toc) {
        try writer.writeAll("<nav class=\"toc\">\n<h2>");
        try escape(writer, st.toc_title());
        try writer.writeAll("</h2>\n<ul>\n");
        for (doc.content) |block| {
            if (block == .heading) {
                const h = block.heading;
                if (h.level > st.toc_depth) continue;
                try writer.print("<li class=\"toc-l{d}\"><a href=\"#{s}\">", .{ h.level, slug(&ctx, h.id, plain(&ctx, h.text)) });
                if (h.number) |n| try writer.print("{s} ", .{n});
                try writeInlines(&ctx, h.text, writer);
                try writer.writeAll("</a></li>\n");
            }
        }
        try writer.writeAll("</ul>\n</nav>\n");
    }

    try writer.writeAll("<div class=\"flow\">\n");
    for (doc.content) |block| try renderBlock(&ctx, block, writer);
    try writer.writeAll("</div>\n");

    try writeFootnotes(&ctx, writer);
    try writer.writeAll("</article>\n</body>\n</html>\n");
}

fn writeCss(writer: anytype, st: style.Style) !void {
    try writer.print("@page {{ size: {d:.2}pt {d:.2}pt; margin: {d:.2}pt {d:.2}pt {d:.2}pt {d:.2}pt; }}\n", .{
        st.paper.width, st.paper.height, st.margins.top, st.margins.right, st.margins.bottom, st.margins.left,
    });

    try writer.print(":root {{ --measure: {d:.2}pt; --size: {d:.2}pt; --leading: {d:.2}pt; --tracking: {d:.4}em; --text: rgb({d}, {d}, {d}); --muted: rgb({d}, {d}, {d}); --accent: rgb({d}, {d}, {d}); --font: {s}; --heading-font: {s}; --mono: {s}; }}\n", .{
        st.measure,
        st.size,
        st.leading,
        st.tracking / st.size,
        @as(u8, @intFromFloat(st.text_color.r * 255)),
        @as(u8, @intFromFloat(st.text_color.g * 255)),
        @as(u8, @intFromFloat(st.text_color.b * 255)),
        @as(u8, @intFromFloat(st.muted_color.r * 255)),
        @as(u8, @intFromFloat(st.muted_color.g * 255)),
        @as(u8, @intFromFloat(st.muted_color.b * 255)),
        @as(u8, @intFromFloat(st.accent_color.r * 255)),
        @as(u8, @intFromFloat(st.accent_color.g * 255)),
        @as(u8, @intFromFloat(st.accent_color.b * 255)),
        fonts.css_name.get("helvetica").?,
        fonts.css_name.get("times").?,
        fonts.css_name.get("courier").?,
    });

    try writer.print("* {{ box-sizing: border-box; }}\n", .{});
    try writer.print("body {{ margin: 0; padding: 2rem 1.5rem; background: #fafafa; color: var(--text); font-family: var(--font); font-size: var(--size); line-height: var(--leading); letter-spacing: var(--tracking); -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; font-kerning: normal; font-variant-numeric: oldstyle-nums; font-optical-sizing: auto; hanging-punctuation: first; text-wrap: pretty; }}\n", .{});
    try writer.print(".doc {{ max-width: var(--measure); margin: 0 auto; background: #fff; padding: 3rem 2.5rem; border-radius: 10px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }}\n", .{});
    try writer.print("p {{ margin: 0 0 var(--leading); text-align: {s}; hyphens: auto; overflow-wrap: break-word; text-wrap: pretty; }}\n", .{if (st.justify) "justify" else "left"});
    try writer.print("h1, h2, h3, h4, h5, h6 {{ font-family: var(--heading-font); font-weight: 650; line-height: 1.25; margin: 0; letter-spacing: {d:.4}em; text-wrap: balance; break-after: avoid; hyphens: manual; }}\n", .{ st.heading_tracking / st.size });
    try writer.print("h1.doctitle {{ font-size: {d:.2}pt; margin-bottom: 1.2rem; letter-spacing: -0.01em; }}\n", .{st.heading_sizes[0]});
    try writer.print(".byline {{ color: var(--muted); font-size: {d:.2}pt; margin-bottom: 2rem; }}\n", .{st.size});

    for (0..6) |i| {
        try writer.print("h{d} {{ font-size: {d:.2}pt; margin: {d:.2}pt 0 {d:.2}pt; }}\n", .{ i + 1, st.heading_sizes[i], st.heading_before[i], st.heading_after[i] });
    }

    try writer.print(".toc ul {{ list-style: none; padding: 0; margin: 0; }}\n", .{});
    try writer.print(".toc li {{ margin: .35rem 0; display: flex; gap: .5rem; }}\n", .{});
    try writer.print(".toc a {{ color: inherit; text-decoration: none; }}\n", .{});
    try writer.print(".toc a:hover {{ color: var(--accent); }}\n", .{});
    try writer.print("blockquote {{ margin: 1.2rem 0; padding: 0 0 0 1rem; border-left: 3px solid var(--accent); color: var(--muted); font-size: {d:.2}pt; }}\n", .{st.quote_size});
    try writer.print("blockquote .source {{ display: block; margin-top: .5rem; font-size: {d:.2}pt; }}\n", .{st.caption_size});
    try writer.print("pre {{ margin: 1.2rem 0; padding: 1rem 1.1rem; background: #f4f5f7; border-radius: 6px; font-family: var(--mono); font-size: {d:.2}pt; line-height: 1.5; overflow-x: auto; white-space: pre-wrap; }}\n", .{st.code_size});
    try writer.print("code {{ font-family: var(--mono); font-size: {d:.2}pt; }}\n", .{st.code_size});
    try writer.print("table {{ border-collapse: collapse; width: 100%; margin: 1.2rem 0; }}\n", .{});
    try writer.print("thead th {{ border-top: 1.2pt solid var(--text); border-bottom: .6pt solid var(--muted); padding: .45rem .6rem; text-align: left; }}\n", .{});
    try writer.print("tbody td {{ padding: .4rem .6rem; }}\n", .{});
    try writer.print("tbody tr:last-child td {{ border-bottom: 1.2pt solid var(--text); }}\n", .{});
    try writer.print("figure {{ margin: 1.2rem 0; }}\n", .{});
    try writer.print("figure img {{ max-width: 100%; height: auto; border-radius: 4px; }}\n", .{});
    try writer.print("figcaption, .caption {{ font-size: {d:.2}pt; color: var(--muted); margin-top: .5rem; }}\n", .{st.caption_size});
    try writer.print(".callout {{ margin: 1.2rem 0; padding: 1rem 1.1rem; border-radius: 6px; border-left: 3px solid var(--accent); background: #f2f5f9; }}\n", .{});
    try writer.print(".callout .title {{ font-weight: 650; margin-bottom: .4rem; }}\n", .{});
    try writer.print(".callout.warning {{ background: #fdf4e7; border-left-color: rgb(183,115,31); }}\n", .{});
    try writer.print(".callout.tip {{ background: #ecf6ee; border-left-color: rgb(46,140,87); }}\n", .{});
    try writer.print(".callout.caution {{ background: #fbeeee; border-left-color: rgb(204,41,41); }}\n", .{});
    try writer.print(".callout.important {{ background: #f1eefb; border-left-color: rgb(102,77,179); }}\n", .{});
    try writer.print("dl {{ margin: 1.2rem 0; }}\n", .{});
    try writer.print("dt {{ font-weight: 650; margin-top: .6rem; }}\n", .{});
    try writer.print("dd {{ margin: .2rem 0 0 1rem; color: var(--muted); }}\n", .{});
    try writer.print(".equation {{ margin: 1.2rem 0; display: flex; align-items: center; gap: 1rem; }}\n", .{});
    try writer.print("math {{ font-size: {d:.2}pt; }}\n", .{st.math_size});
    try writer.print(".equation .number {{ margin-left: auto; color: var(--muted); font-size: {d:.2}pt; font-variant-numeric: tabular-nums; }}\n", .{st.caption_size});
    try writer.print("math {{ display: block; margin: 0; }}\n", .{});
    try writer.print("p math {{ display: inline; }}\n", .{});
    try writer.print("math math {{ display: inline; }}\n", .{});
    try writer.print("ul, ol {{ margin: 1rem 0; padding-left: 1.4rem; }}\n", .{});
    try writer.print("li {{ margin: .3rem 0; text-align: {s}; hyphens: auto; text-wrap: pretty; }}\n", .{if (st.justify) "justify" else "left"});
    try writer.print("li > p {{ margin: 0; }}\n", .{});
    try writer.print("hr {{ border: 0; border-top: .6pt solid var(--muted); margin: 1.5rem 0; }}\n", .{});
    try writer.print("a {{ color: var(--accent); text-decoration: none; }}\n", .{});
    try writer.print("sup, sub {{ font-size: .7em; }}\n", .{});
    try writer.print(".pagebreak {{ break-before: page; }}\n", .{});
    try writer.print(".columnbreak {{ break-before: column; }}\n", .{});
    try writer.print(".footnotes {{ margin-top: 2.5rem; border-top: .6pt solid var(--muted); padding-top: .8rem; font-size: {d:.2}pt; color: var(--muted); }}\n", .{st.footnote_size});
    try writer.print(".fnref {{ font-size: .7em; vertical-align: super; line-height: 0; }}\n", .{});
    try writer.print(".footnotes ol {{ padding-left: 1.2rem; }}\n", .{});
    try writer.print(".footnotes li {{ margin: .4rem 0; text-align: {s}; hyphens: auto; }}\n", .{if (st.justify) "justify" else "left"});
    try writer.print(".backlink {{ color: inherit; text-decoration: none; margin-left: .3rem; }}\n", .{});
    if (st.columns > 1) {
        try writer.print(".flow {{ column-count: {d}; column-gap: {d:.2}pt; column-fill: auto; }}\n", .{ st.columns, st.column_gap });
        try writer.print(".flow > * {{ break-inside: avoid; }}\n", .{});
    }
    try writer.print(".bibliography {{ margin-top: 2rem; }}\n", .{});
    try writer.print(".bib-list {{ list-style: none; padding-left: 0; margin: 1rem 0; }}\n", .{});
    try writer.print(".bib-list li {{ margin: .4rem 0; padding-left: 2.2em; text-indent: -2.2em; text-align: {s}; hyphens: auto; text-wrap: pretty; }}\n", .{if (st.justify) "justify" else "left"});
    try writer.print(".bib-number {{ color: var(--muted); font-variant-numeric: tabular-nums; }}\n", .{});
    try writer.print("a.cite {{ color: var(--accent); text-decoration: none; font-variant-numeric: tabular-nums; }}\n", .{});
    try writer.print("a.cite:target, .bib-list li:target {{ background: #f6f8fb; outline: 1px solid var(--accent); }}\n", .{});
    try writer.print("@media print {{ body {{ background: #fff; padding: 0; }} .doc {{ box-shadow: none; padding: 0; max-width: none; }} h1, h2, h3, h4 {{ break-after: avoid; }} p, li, blockquote {{ orphans: {d}; widows: {d}; }} figure, .callout, table {{ break-inside: avoid; }} }}\n", .{ st.orphans, st.widows });
}

fn slug(ctx: *Ctx, id: ?[]const u8, title: []const u8) []const u8 {
    if (id) |i| return i;
    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    for (title) |c| {
        if (std.ascii.isAlphanumeric(c) or c >= 0x80) {
            buf.append(c) catch {};
        } else if (c == ' ' or c == '-' or c == '_') {
            buf.append('-') catch {};
        }
    }
    const out = buf.toOwnedSlice() catch "";
    if (out.len == 0) return "section";
    return out;
}

fn renderBlock(ctx: *Ctx, block: ast.Block, writer: anytype) !void {
    switch (block) {
        .heading => |h| {
            try writer.print("<h{d} id=\"{s}\">", .{ h.level, slug(ctx, h.id, plain(ctx, h.text)) });
            if (h.number) |n| try writer.print("<span class=\"number\">{s}</span> ", .{n});
            try writeInlines(ctx, h.text, writer);
            try writer.print("</h{d}>\n", .{h.level});
        },
        .paragraph => |p| {
            try writer.writeAll("<p>");
            try writeInlines(ctx, p.content, writer);
            try writer.writeAll("</p>\n");
        },
        .list => |l| {
            try writer.writeAll(if (l.ordered) "<ol>\n" else "<ul>\n");
            for (l.items) |item| {
                try writer.writeAll("<li>");
                try writeInlines(ctx, item.content, writer);
                if (item.children.len > 0) try renderList(ctx, item.children, writer);
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll(if (l.ordered) "</ol>\n" else "</ul>\n");
        },
        .quote => |q| {
            try writer.writeAll("<blockquote>\n");
            for (q.content) |b| try renderBlock(ctx, b, writer);
            if (q.source) |src| try writer.print("<span class=\"source\">{s}</span>\n", .{src});
            try writer.writeAll("</blockquote>\n");
        },
        .code => |c| {
            try writer.writeAll("<figure class=\"listing\">\n");
            if (c.number != null or c.caption != null) {
                try writer.writeAll("<figcaption>");
                if (c.number) |n| try writer.print("{s}", .{n});
                if (c.caption) |cap| try writer.print(" {s}", .{cap});
                try writer.writeAll("</figcaption>\n");
            }
            try writer.print("<pre><code{?s}>", .{if (c.language) |lng| blk: {
                const buf = std.fmt.allocPrint(ctx.allocator, " class=\"language-{s}\"", .{lng}) catch "";
                break :blk buf;
            } else null});
            try escape(writer, c.source);
            try writer.writeAll("</code></pre>\n</figure>\n");
        },
        .figure => |f| {
            try writer.writeAll("<figure");
            if (f.id) |id| try writer.print(" id=\"{s}\"", .{id});
            try writer.writeAll(">\n");
            if (f.src) |src| {
                try writer.print("<img src=\"{s}\" alt=\"{s}\">\n", .{ src, f.alt orelse "" });
            }
            if (f.caption != null) {
                try writer.writeAll("<figcaption>");
                if (f.number) |n| try writer.print("{s}", .{n});
                if (f.caption) |cap| try writer.print(" {s}", .{cap});
                try writer.writeAll("</figcaption>\n");
            }
            try writer.writeAll("</figure>\n");
        },
        .table => |t| {
            try writer.writeAll("<table");
            if (t.id) |id| try writer.print(" id=\"{s}\"", .{id});
            try writer.writeAll(">\n");
            if (t.caption != null) {
                try writer.writeAll("<caption>");
                if (t.number) |n| try writer.print("{s}", .{n});
                if (t.caption) |cap| try writer.print(" {s}", .{cap});
                try writer.writeAll("</caption>\n");
            }
            try writeColgroup(ctx, t, writer);
            if (t.headers.len > 0) {
                try writer.writeAll("<thead><tr>");
                for (t.headers, 0..) |cell, i| {
                    try writer.print("<th{?s}>", .{alignAttr(t.alignments, i)});
                    try writeInlines(ctx, cell, writer);
                    try writer.writeAll("</th>");
                }
                try writer.writeAll("</tr></thead>\n");
            }
            try writer.writeAll("<tbody>\n");
            for (t.rows) |row| {
                try writer.writeAll("<tr>");
                for (row, 0..) |cell, i| {
                    try writer.print("<td{?s}>", .{alignAttr(t.alignments, i)});
                    try writeInlines(ctx, cell, writer);
                    try writer.writeAll("</td>");
                }
                try writer.writeAll("</tr>\n");
            }
            try writer.writeAll("</tbody>\n</table>\n");
        },
        .callout => |c| {
            try writer.print("<div class=\"callout {s}\"", .{@tagName(c.kind)});
            if (c.id) |id| try writer.print(" id=\"{s}\"", .{id});
            try writer.writeAll(">\n");
            if (c.title) |title| try writer.print("<div class=\"title\">{s}</div>\n", .{title});
            for (c.content) |b| try renderBlock(ctx, b, writer);
            try writer.writeAll("</div>\n");
        },
        .math => |m| {
            try writer.writeAll("<div class=\"equation\"");
            if (m.id) |id| try writer.print(" id=\"{s}\"", .{id});
            try writer.writeAll("><math display=\"block\">");
            for (m.nodes) |node| {
                if (node == .tag) continue;
                try writeMathMLNode(writer, node);
            }
            try writer.writeAll("</math>");
            var tag: ?math.Tag = null;
            for (m.nodes) |node| {
                if (node == .tag) {
                    tag = node.tag;
                    break;
                }
            }
            if (tag) |t| {
                if (!t.suppress) {
                    try writer.writeAll("<span class=\"number\"><math>");
                    try writeMathMLNode(writer, t.body.*);
                    try writer.writeAll("</math></span>");
                }
            } else if (m.number) |n| try writer.print("<span class=\"number\">{s}</span>", .{n});
            try writer.writeAll("</div>\n");
        },
        .definition_list => |d| {
            try writer.writeAll("<dl>\n");
            for (d.entries) |entry| {
                try writer.writeAll("<dt>");
                try writeInlines(ctx, entry.term, writer);
                try writer.writeAll("</dt><dd>");
                try writeInlines(ctx, entry.definition, writer);
                try writer.writeAll("</dd>\n");
            }
            try writer.writeAll("</dl>\n");
        },
        .bibliography => |b| {
            try writer.writeAll("<section class=\"bibliography\"");
            if (b.id) |id| try writer.print(" id=\"{s}\"", .{id});
            try writer.writeAll(">\n");
            try writer.print("<h2 class=\"bib-title\">{s}</h2>\n", .{b.title orelse ctx.st.bibliography_label()});
            try writer.writeAll("<ol class=\"bib-list\">\n");
            for (b.entries) |entry| {
                const n = ctx.citations.get(entry.key);
                try writer.print("<li id=\"bib-{s}\">", .{entry.key});
                try writer.print("<span class=\"bib-number\">{?s}</span> ", .{if (n) |num| blk: {
                    const buf = std.fmt.allocPrint(ctx.allocator, "[{d}]", .{num}) catch "";
                    break :blk buf;
                } else null});
                try writeInlines(ctx, entry.text, writer);
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ol>\n</section>\n");
        },
        .page_break => try writer.writeAll("<div class=\"pagebreak\"></div>\n"),
        .column_break => try writer.writeAll("<div class=\"columnbreak\"></div>\n"),
        .rule => try writer.writeAll("<hr>\n"),
        .toc => {},
        .script => {},
    }
}

fn renderList(ctx: *Ctx, items: []ast.ListItem, writer: anytype) !void {
    try writer.writeAll("<ol>\n");
    for (items) |item| {
        try writer.writeAll("<li>");
        try writeInlines(ctx, item.content, writer);
        if (item.children.len > 0) try renderList(ctx, item.children, writer);
        try writer.writeAll("</li>\n");
    }
    try writer.writeAll("</ol>\n");
}

fn collectAllFootnotes(ctx: *Ctx) ![]const []const u8 {
    var out = std.array_list.Managed([]const u8).init(ctx.allocator);
    for (ctx.doc.content) |block| collectBlockFootnotes(ctx, block, &out);
    return out.toOwnedSlice();
}

fn collectBlockFootnotes(ctx: *Ctx, block: ast.Block, out: *std.array_list.Managed([]const u8)) void {
    switch (block) {
        .paragraph => |p| collectFootnotes(ctx, p.content, out),
        .heading => |h| collectFootnotes(ctx, h.text, out),
        .list => |l| {
            for (l.items) |item| collectItemFootnotes(ctx, item, out);
        },
        .quote => |q| for (q.content) |b| collectBlockFootnotes(ctx, b, out),
        .callout => |c| for (c.content) |b| collectBlockFootnotes(ctx, b, out),
        else => {},
    }
}

fn collectItemFootnotes(ctx: *Ctx, item: ast.ListItem, out: *std.array_list.Managed([]const u8)) void {
    collectFootnotes(ctx, item.content, out);
    for (item.children) |child| collectItemFootnotes(ctx, child, out);
}

fn collectFootnotes(ctx: *Ctx, inlines: []ast.Inline, out: *std.array_list.Managed([]const u8)) void {
    for (inlines) |node| {
        switch (node) {
            .footnote => |kids| {
                out.append(plain(ctx, kids)) catch return;
                collectFootnotes(ctx, kids, out);
            },
            .strong, .em, .sup, .sub => |kids| collectFootnotes(ctx, kids, out),
            .link => |l| collectFootnotes(ctx, l.text, out),
            else => {},
        }
    }
}

fn writeFootnotes(ctx: *Ctx, writer: anytype) !void {
    if (ctx.footnotes.len == 0) return;
    try writer.writeAll("<section class=\"footnotes\">\n<ol>\n");
    for (ctx.footnotes, 1..) |text, i| {
        try writer.print("<li id=\"fn-{d}\">{s}<a class=\"backlink\" href=\"#fnref-{d}\" aria-label=\"back to text\">↩</a></li>\n", .{ i, text, i });
    }
    try writer.writeAll("</ol>\n</section>\n");
}

fn buildCitations(ctx: *Ctx) void {
    ctx.citations = std.StringHashMap(usize).init(ctx.allocator);
    var n: usize = 0;
    for (ctx.doc.content) |block| citePassBlock(ctx, block, &n);
    for (ctx.doc.content) |block| {
        if (block == .bibliography) {
            for (block.bibliography.entries) |e| {
                if (ctx.citations.get(e.key) == null) {
                    n += 1;
                    ctx.citations.put(e.key, n) catch {};
                }
            }
        }
    }
}

fn citePassBlock(ctx: *Ctx, block: ast.Block, n: *usize) void {
    switch (block) {
        .paragraph => |p| citePassInlines(ctx, p.content, n),
        .heading => |h| citePassInlines(ctx, h.text, n),
        .list => |l| {
            for (l.items) |item| citePassItem(ctx, item, n);
        },
        .quote => |q| for (q.content) |b| citePassBlock(ctx, b, n),
        .callout => |c| for (c.content) |b| citePassBlock(ctx, b, n),
        .table => |t| {
            for (t.headers) |cell| citePassInlines(ctx, cell, n);
            for (t.rows) |row| for (row) |cell| citePassInlines(ctx, cell, n);
        },
        else => {},
    }
}

fn citePassItem(ctx: *Ctx, item: ast.ListItem, n: *usize) void {
    citePassInlines(ctx, item.content, n);
    for (item.children) |child| citePassItem(ctx, child, n);
}

fn citePassInlines(ctx: *Ctx, inlines: []const ast.Inline, n: *usize) void {
    for (inlines) |node| {
        switch (node) {
            .cite => |key| {
                if (ctx.citations.get(key) == null) {
                    n.* += 1;
                    ctx.citations.put(key, n.*) catch {};
                }
            },
            .strong, .em, .sup, .sub, .footnote => |kids| citePassInlines(ctx, kids, n),
            .link => |l| citePassInlines(ctx, l.text, n),
            else => {},
        }
    }
}

fn plain(ctx: *Ctx, inlines: []ast.Inline) []const u8 {
    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    for (inlines) |node| {
        switch (node) {
            .text, .code, .expr, .ref => |s| buf.appendSlice(s) catch {},
            .cite => |key| {
                if (ctx.citations.get(key)) |num| {
                    buf.appendSlice(std.fmt.allocPrint(ctx.allocator, "[{d}]", .{num}) catch "") catch {};
                } else {
                    buf.appendSlice("[") catch {};
                    buf.appendSlice(key) catch {};
                    buf.appendSlice("]") catch {};
                }
            },
            .strong, .em, .sup, .sub, .footnote => |kids| buf.appendSlice(plain(ctx, kids)) catch {},
            .link => |l| {
                buf.appendSlice(plain(ctx, l.text)) catch {};
                buf.appendSlice(" (") catch {};
                buf.appendSlice(l.url) catch {};
                buf.appendSlice(")") catch {};
            },
            .math => |nodes| {
                for (nodes) |child| buf.appendSlice(plainMath(ctx, child)) catch {};
            },
        }
    }
    return buf.toOwnedSlice() catch "";
}

fn plainMath(ctx: *Ctx, node: math.Node) []const u8 {
    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    switch (node) {
        .glyph => |g| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(g.cp, &bytes) catch 0;
            buf.appendSlice(bytes[0..n]) catch {};
        },
        .text => |t| buf.appendSlice(t) catch {},
        .row => |r| {
            for (r) |x| buf.appendSlice(plainMath(ctx, x)) catch {};
        },
        .frac => |f| {
            buf.appendSlice(plainMath(ctx, f.num.*)) catch {};
            buf.appendSlice("/") catch {};
            buf.appendSlice(plainMath(ctx, f.denom.*)) catch {};
        },
        .script => |s| {
            buf.appendSlice(plainMath(ctx, s.base.*)) catch {};
            if (s.sup) |x| {
                buf.appendSlice("^") catch {};
                buf.appendSlice(plainMath(ctx, x.*)) catch {};
            }
            if (s.sub) |x| {
                buf.appendSlice("_") catch {};
                buf.appendSlice(plainMath(ctx, x.*)) catch {};
            }
        },
        else => buf.appendSlice("(formula)") catch {},
    }
    return buf.toOwnedSlice() catch "";
}

fn writeInlines(ctx: *Ctx, inlines: []ast.Inline, writer: anytype) !void {
    for (inlines) |node| {
        switch (node) {
            .text => |s| try escape(writer, s),
            .code => |s| try writer.print("<code>{s}</code>", .{s}),
            .strong => |kids| {
                try writer.writeAll("<strong>");
                try writeInlines(ctx, kids, writer);
                try writer.writeAll("</strong>");
            },
            .em => |kids| {
                try writer.writeAll("<em>");
                try writeInlines(ctx, kids, writer);
                try writer.writeAll("</em>");
            },
            .sup => |kids| {
                try writer.writeAll("<sup>");
                try writeInlines(ctx, kids, writer);
                try writer.writeAll("</sup>");
            },
            .sub => |kids| {
                try writer.writeAll("<sub>");
                try writeInlines(ctx, kids, writer);
                try writer.writeAll("</sub>");
            },
            .link => |l| {
                try writer.print("<a href=\"{s}\">", .{l.url});
                try writeInlines(ctx, l.text, writer);
                try writer.writeAll("</a>");
            },
            .ref => |id| try writer.print("<a class=\"ref\" href=\"#{s}\">{s}</a>", .{ id, id }),
            .cite => |key| {
                const label = if (ctx.citations.get(key)) |num| blk: {
                    const buf = std.fmt.allocPrint(ctx.allocator, "[{d}]", .{num}) catch "";
                    break :blk buf;
                } else key;
                try writer.print("<a class=\"cite\" href=\"#bib-{s}\">{s}</a>", .{ key, label });
            },
            .footnote => |kids| {
                ctx.counter += 1;
                const n = ctx.counter;
                try writer.print("<sup class=\"fnref\"><a href=\"#fn-{d}\" id=\"fnref-{d}\">{d}</a></sup>", .{ n, n, n });
                _ = kids;
            },
            .expr => |s| {
                if (ctx.resolver) |r| {
                    if (r.evalExpr(s)) |v| {
                        if (v) |val| {
                            try escape(writer, val);
                            continue;
                        }
                    } else |_| {}
                }
                try escape(writer, s);
            },
            .math => |nodes| {
                try writer.writeAll("<math>");
                try writeMathML(writer, nodes);
                try writer.writeAll("</math>");
            },
        }
    }
}

fn writeMathML(writer: anytype, nodes: []math.Node) !void {
    for (nodes) |node| try writeMathMLNode(writer, node);
}

fn writeMathMLNode(writer: anytype, node: math.Node) !void {
    switch (node) {
        .glyph => |g| {
            const tag = switch (g.class) {
                .number => "mn",
                .letter => "mi",
                .operator, .punctuation, .delimiter => "mo",
                .function => "mi",
                .symbol => "mo",
            };
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(g.cp, &bytes) catch 0;
            try writer.print("<{s}>{s}</{s}>", .{ tag, bytes[0..n], tag });
        },
        .text => |t| try writer.print("<mtext>{s}</mtext>", .{t}),
        .row => |r| {
            try writer.writeAll("<mrow>");
            for (r) |x| try writeMathMLNode(writer, x);
            try writer.writeAll("</mrow>");
        },
        .frac => |f| {
            try writer.writeAll("<mfrac>");
            try writeMathMLNode(writer, f.num.*);
            try writeMathMLNode(writer, f.denom.*);
            try writer.writeAll("</mfrac>");
        },
        .sqrt => |s| {
            if (s.index) |idx| {
                try writer.writeAll("<mroot>");
                try writeMathMLNode(writer, s.body.*);
                try writeMathMLNode(writer, idx.*);
                try writer.writeAll("</mroot>");
            } else {
                try writer.writeAll("<msqrt>");
                try writeMathMLNode(writer, s.body.*);
                try writer.writeAll("</msqrt>");
            }
        },
        .script => |s| {
            if (s.limits) {
                if (s.sup != null and s.sub != null) {
                    try writer.writeAll("<munderover>");
                    try writeMathMLNode(writer, s.base.*);
                    try writeMathMLNode(writer, s.sub.?.*);
                    try writeMathMLNode(writer, s.sup.?.*);
                    try writer.writeAll("</munderover>");
                } else if (s.sub != null) {
                    try writer.writeAll("<munder>");
                    try writeMathMLNode(writer, s.base.*);
                    try writeMathMLNode(writer, s.sub.?.*);
                    try writer.writeAll("</munder>");
                } else {
                    try writer.writeAll("<mover>");
                    try writeMathMLNode(writer, s.base.*);
                    try writeMathMLNode(writer, s.sup.?.*);
                    try writer.writeAll("</mover>");
                }
            } else if (s.sup != null and s.sub != null) {
                try writer.writeAll("<msubsup>");
                try writeMathMLNode(writer, s.base.*);
                try writeMathMLNode(writer, s.sub.?.*);
                try writeMathMLNode(writer, s.sup.?.*);
                try writer.writeAll("</msubsup>");
            } else if (s.sup != null) {
                try writer.writeAll("<msup>");
                try writeMathMLNode(writer, s.base.*);
                try writeMathMLNode(writer, s.sup.?.*);
                try writer.writeAll("</msup>");
            } else {
                try writer.writeAll("<msub>");
                try writeMathMLNode(writer, s.base.*);
                try writeMathMLNode(writer, s.sub.?.*);
                try writer.writeAll("</msub>");
            }
        },
        .accent => |a| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(a.cp, &bytes) catch 0;
            try writer.writeAll("<mover accent=\"true\">");
            try writeMathMLNode(writer, a.base.*);
            try writer.print("<mo>{s}</mo>", .{bytes[0..n]});
            try writer.writeAll("</mover>");
        },
        .over_under => |o| {
            try writer.writeAll(if (o.above) "<mover accent=\"true\">" else "<munder accent=\"true\">");
            try writeMathMLNode(writer, o.base.*);
            try writeMathMLNode(writer, o.mark.*);
            try writer.writeAll(if (o.above) "</mover>" else "</munder>");
        },
        .tag => |t| try writeMathMLNode(writer, t.body.*),
        .delim => |d| {
            var left: [4]u8 = undefined;
            var right: [4]u8 = undefined;
            const ln = std.unicode.utf8Encode(d.left, &left) catch 0;
            const rn = std.unicode.utf8Encode(d.right, &right) catch 0;
            try writer.writeAll("<mrow>");
            try writer.print("<mo stretchy=\"{s}\">{s}</mo>", .{ if (d.stretchy) "true" else "false", left[0..ln] });
            try writeMathMLNode(writer, d.body.*);
            try writer.print("<mo stretchy=\"{s}\">{s}</mo>", .{ if (d.stretchy) "true" else "false", right[0..rn] });
            try writer.writeAll("</mrow>");
        },
        .matrix => |m| {
            var left: [4]u8 = undefined;
            var right: [4]u8 = undefined;
            const ln = std.unicode.utf8Encode(m.left, &left) catch 0;
            const rn = std.unicode.utf8Encode(m.right, &right) catch 0;
            try writer.writeAll("<mrow>");
            if (m.left != 0) try writer.print("<mo stretchy=\"true\">{s}</mo>", .{left[0..ln]});
            try writer.writeAll("<mtable>");
            for (m.rows) |row| {
                try writer.writeAll("<mtr>");
                for (row) |cell| {
                    try writer.writeAll("<mtd>");
                    try writeMathMLNode(writer, cell);
                    try writer.writeAll("</mtd>");
                }
                try writer.writeAll("</mtr>");
            }
            try writer.writeAll("</mtable>");
            if (m.right != 0) try writer.print("<mo stretchy=\"true\">{s}</mo>", .{right[0..rn]});
            try writer.writeAll("</mrow>");
        },
        .cases => |c| {
            var left: [4]u8 = undefined;
            const ln = std.unicode.utf8Encode(c.left, &left) catch 0;
            try writer.writeAll("<mrow>");
            try writer.print("<mo stretchy=\"true\">{s}</mo>", .{left[0..ln]});
            try writer.writeAll("<mtable>");
            for (c.rows) |row| {
                try writer.writeAll("<mtr>");
                for (row) |cell| {
                    try writer.writeAll("<mtd>");
                    try writeMathMLNode(writer, cell);
                    try writer.writeAll("</mtd>");
                }
                try writer.writeAll("</mtr>");
            }
            try writer.writeAll("</mtable>");
            try writer.writeAll("</mrow>");
        },
        .stack => |s| {
            try writer.writeAll("<mtable>");
            for (s.items) |item| {
                try writer.writeAll("<mtr><mtd>");
                try writeMathMLNode(writer, item.*);
                try writer.writeAll("</mtd></mtr>");
            }
            try writer.writeAll("</mtable>");
        },
        .binom => |b| {
            try writer.writeAll("<mrow><mo stretchy=\"true\">(</mo><mtable><mtr><mtd>");
            try writeMathMLNode(writer, b.top.*);
            try writer.writeAll("</mtd></mtr><mtr><mtd>");
            try writeMathMLNode(writer, b.bottom.*);
            try writer.writeAll("</mtd></mtr></mtable><mo stretchy=\"true\">)</mo></mrow>");
        },
        .space => |w| try writer.print("<mspace width=\"{d}em\"/>", .{w}),
        .rule => |r| try writer.print("<mrow><mo style=\"border-top:{d}em solid;min-width:{d}em\"></mo></mrow>", .{ r.thickness, r.length }),
        .op => |o| try writer.print("<mo>{s}</mo>", .{o.name}),
        .style => |s| {
            try writer.print("<mrow class=\"math-style-{s}\">", .{@tagName(s.font)});
            try writeMathMLNode(writer, s.body.*);
            try writer.writeAll("</mrow>");
        },
    }
}

fn alignAttr(alignments: []ast.Alignment, index: usize) ?[]const u8 {
    if (index >= alignments.len) return null;
    return switch (alignments[index]) {
        .left => " style=\"text-align:left\"",
        .center => " style=\"text-align:center\"",
        .right => " style=\"text-align:right\"",
    };
}

/// 显式列宽（对齐行里的 `<2cm`、`^30%`、`>2fr`）在 HTML 里用 colgroup 表达；
/// 未指定宽度的列交给浏览器按内容分配
fn writeColgroup(ctx: *Ctx, t: ast.Table, writer: anytype) !void {
    const cols = @max(t.headers.len, if (t.rows.len > 0) t.rows[0].len else 0);
    var fr_total: f64 = 0;
    var explicit = false;
    for (t.widths) |w| {
        if (w == .auto) continue;
        explicit = true;
        if (w == .fr) fr_total += w.fr;
    }
    if (!explicit or cols == 0) return;

    try writer.writeAll("<colgroup>\n");
    for (0..cols) |c| {
        const spec: ast.ColumnWidth = if (c < t.widths.len) t.widths[c] else ast.ColumnWidth{ .auto = {} };
        if (spec == .auto) {
            try writer.writeAll("<col>\n");
            continue;
        }
        const pct = switch (spec) {
            .fraction => |f| f * 100.0,
            .length => |l| l / @max(ctx.st.measure, 1.0) * 100.0,
            .fr => |v| if (fr_total > 0) v / fr_total * 100.0 else 0.0,
            .auto => 0.0,
        };
        try writer.print("<col style=\"width: {d:.2}%\">\n", .{pct});
    }
    try writer.writeAll("</colgroup>\n");
}

fn escape(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}
