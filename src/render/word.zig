//! Ztype RTF（Word）后端
//! 从 AST 输出富文本格式：字体表、样式表、标题编号、上下标、脚注、表格与链接。

const std = @import("std");
const ast = @import("../ast.zig");
const engine = @import("../engine.zig");
const style = @import("../style.zig");
const fonts = @import("../fonts.zig");
const cjk = @import("../util/cjk.zig");
const math = @import("../math.zig");
const Resolver = @import("../resolver.zig").Resolver;

const RtfError = std.Io.Writer.Error || error{OutOfMemory};

const Ctx = struct {
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    eng: *const engine.Engine,
    resolver: ?*const Resolver,
    writer: *std.Io.Writer,
    fn_index: usize = 0,
};

/// RTF 字号以半磅计，长度以 twips 计（1pt = 20 twips）
fn halfPoints(d: f64) i32 {
    return @intFromFloat(@round(d * 2.0));
}

fn twips(d: f64) i32 {
    return @intFromFloat(@round(d * 20.0));
}

fn fontIndex(font: fonts.Font) usize {
    return switch (font) {
        .helvetica, .helvetica_bold, .helvetica_oblique => 0,
        .times, .times_bold, .times_italic => 1,
        .courier, .courier_bold => 2,
        .symbol => 3,
        .cjk => 4,
    };
}

fn citeLabel(ctx: *Ctx, key: []const u8, fallback: ?usize) []const u8 {
    if (ctx.eng.refs.get(key)) |ref| return ref.number;
    if (fallback) |i| return std.fmt.allocPrint(ctx.allocator, "{d}", .{i}) catch key;
    return key;
}

const Fmt = struct {
    font: fonts.Font,
    size: f64,
    bold: bool = false,
    italic: bool = false,
    color: ?style.Color = null,
    underline: bool = false,
};

pub fn render(
    allocator: std.mem.Allocator,
    doc: *const ast.Document,
    eng: *const engine.Engine,
    resolver: ?*const Resolver,
    writer: *std.Io.Writer,
) RtfError!void {
    const st = eng.style;
    var ctx = Ctx{ .allocator = allocator, .doc = doc, .eng = eng, .resolver = resolver, .writer = writer };

    try ctx.writer.writeAll("{\\rtf1\\ansi\\ansicpg1252\\deff0\\deflang1033\\uc2\n");
    try ctx.writer.writeAll("{\\fonttbl{\\f0\\fswiss Helvetica;}{\\f1\\froman Times New Roman;}{\\f2\\fmodern Courier New;}{\\f3\\fsymbol Symbol;}{\\f4\\fnil SimSun;}}\n");
    try writeStylesheet(&ctx, st);

    try ctx.writer.print("\\paperw{d}\\paperh{d}\\margl{d}\\margr{d}\\margt{d}\\margb{d}\n", .{
        twips(st.paper.width),
        twips(st.paper.height),
        twips(st.margins.left),
        twips(st.margins.right),
        twips(st.margins.top),
        twips(st.margins.bottom),
    });

    try ctx.writer.writeAll("{\\info{\\title ");
    try writePlain(&ctx, doc.metadata.getOr("title", "Untitled"));
    try ctx.writer.writeAll("}{\\author ");
    try writePlain(&ctx, doc.metadata.getOr("author", ""));
    try ctx.writer.writeAll("}{\\creator (Ztype)}}\n");

    for (doc.content) |block| try renderBlock(&ctx, block, st);

    try ctx.writer.writeAll("}\n");
}

fn writeStylesheet(ctx: *Ctx, st: style.Style) RtfError!void {
    const body = halfPoints(st.size);
    const leading = twips(st.leading);
    const sa = twips(st.parskip);

    try ctx.writer.print("{{\\stylesheet{{\\s1\\ql\\fi0\\li0\\sb0\\sa{d}\\f0\\fs{d}\\lines{d} body;}}}}\n", .{ sa, body, leading });
    for (0..6) |i| {
        try ctx.writer.print("{{\\s{d}\\ql\\li0\\fi0\\sb{d}\\sa{d}\\b\\f0\\fs{d} heading{d};}}\n", .{
            i + 2,
            twips(st.heading_before[i]),
            twips(st.heading_after[i]),
            halfPoints(st.heading_sizes[i]),
            i + 1,
        });
    }
    try ctx.writer.print("{{\\s8\\ql\\li360\\fi0\\sb0\\sa{d}\\f0\\fs{d} list;}}\n", .{ twips(st.parskip * 0.6), halfPoints(st.size) });
    try ctx.writer.print("{{\\s9\\ql\\li720\\fi0\\sb{d}\\sa{d}\\i\\f0\\fs{d} quote;}}\n", .{ twips(st.parskip), twips(st.parskip), halfPoints(st.quote_size) });
    try ctx.writer.print("{{\\s10\\ql\\li0\\fi0\\sb0\\sa{d}\\f0\\fs{d} caption;}}\n", .{ twips(st.parskip * 0.5), halfPoints(st.caption_size) });
    try ctx.writer.print("{{\\s11\\ql\\li0\\fi0\\sb0\\sa{d}\\f0\\fs{d} footnote;}}\n", .{ twips(st.parskip * 0.4), halfPoints(st.footnote_size) });
    try ctx.writer.print("{{\\s12\\ql\\li0\\fi0\\sb0\\sa{d}\\f2\\fs{d} code;}}\n", .{ twips(st.parskip * 0.5), halfPoints(st.code_size) });
    try ctx.writer.print("{{\\s13\\ql\\li440\\fi-440\\sb0\\sa{d}\\f0\\fs{d} bibliography;}}\n", .{ twips(st.parskip * 0.6), halfPoints(st.size) });
}

fn renderBlock(ctx: *Ctx, block: ast.Block, st: style.Style) RtfError!void {
    switch (block) {
        .heading => |h| {
            const level: usize = @min(6, @as(usize, h.level));
            try ctx.writer.print("\\pard\\plain\\s{d}", .{level + 1});
            if (st.justify) try ctx.writer.writeAll("\\qj");
            try ctx.writer.writeAll(" ");
            if (h.number) |n| try ctx.writer.print("{s} ", .{n});
            try writeInlines(ctx, h.text, .{ .font = fonts.familyFont(st.heading_family, .bold), .size = st.heading_sizes[level - 1], .bold = true });
            try ctx.writer.writeAll("\\par\n");
        },
        .paragraph => |p| {
            try ctx.writer.writeAll("\\pard\\plain\\s1");
            if (st.justify) try ctx.writer.writeAll("\\qj");
            if (st.indent > 0) try ctx.writer.print("\\fi{d}", .{twips(st.indent)});
            try ctx.writer.writeAll(" ");
            try writeInlines(ctx, p.content, .{ .font = fonts.familyFont(st.family, .regular), .size = st.size });
            try ctx.writer.writeAll("\\par\n");
        },
        .list => |l| {
            for (l.items, 1..) |item, i| try renderListItem(ctx, item, st, l.ordered, i, 0);
        },
        .quote => |q| {
            try ctx.writer.writeAll("\\pard\\plain\\s9 ");
            for (q.content) |child| try renderBlock(ctx, child, st);
            if (q.source) |src| {
                try ctx.writer.print("\\pard\\plain\\s10 \\li720 \\emdash {s}\\par\n", .{src});
            }
        },
        .code => |c| {
            try ctx.writer.writeAll("\\pard\\plain\\s12 ");
            var lines = std.mem.splitScalar(u8, c.source, '\n');
            var first = true;
            while (lines.next()) |line| {
                if (!first) try ctx.writer.writeAll("\\par\n");
                first = false;
                try writePlain(ctx, line);
            }
            try ctx.writer.writeAll("\\par\n");
            if (c.caption) |cap| try ctx.writer.print("\\pard\\plain\\s10 {s}{s}\\par\n", .{ numberLabel(ctx, c.number), cap });
        },
        .figure => |f| {
            try ctx.writer.writeAll("\\pard\\plain\\s10 ");
            if (f.src) |src| try ctx.writer.print("[image: {s}]\\par\\pard\\plain\\s10 ", .{src});
            try ctx.writer.print("{s}{s}\\par\n", .{ numberLabel(ctx, f.number), f.caption orelse "" });
        },
        .table => |t| try renderTable(ctx, t, st),
        .callout => |c| {
            try ctx.writer.print("\\pard\\plain\\s1 \\b {s}\\par\\pard\\plain\\s1 ", .{calloutTitle(c.kind)});
            for (c.content) |child| try renderBlock(ctx, child, st);
        },
        .math => |m| {
            try ctx.writer.print("\\pard\\plain\\s1 \\li0\\fi0\\i {s}\\par\n", .{plainMathAll(ctx, m.nodes)});
            if (m.caption) |cap| try ctx.writer.print("\\pard\\plain\\s10 {s}{s}\\par\n", .{ numberLabel(ctx, m.number), cap });
        },
        .definition_list => |d| {
            for (d.entries) |e| {
                try ctx.writer.writeAll("\\pard\\plain\\s1 ");
                try writeInlines(ctx, e.term, .{ .font = fonts.familyFont(st.family, .bold), .size = st.size, .bold = true });
                try ctx.writer.writeAll(" ");
                try writeInlines(ctx, e.definition, .{ .font = fonts.familyFont(st.family, .regular), .size = st.size });
                try ctx.writer.writeAll("\\par\n");
            }
        },
        .bibliography => |b| {
            try ctx.writer.print("\\pard\\plain\\s2 \\b {s}\\par\n", .{b.title orelse st.bibliography_label()});
            for (b.entries, 1..) |entry, i| {
                const label = std.fmt.allocPrint(ctx.allocator, "[{s}]", .{citeLabel(ctx, entry.key, i)}) catch "";
                try ctx.writer.print("\\pard\\plain\\s13 {s} ", .{label});
                try writeInlines(ctx, entry.text, .{ .font = fonts.familyFont(st.family, .regular), .size = st.size });
                try ctx.writer.writeAll("\\par\n");
            }
        },
        .page_break => {
            try ctx.writer.writeAll("\\page\n");
        },
        .column_break => {
            // RTF 没有栏断页指令：单栏时等价于分页
            try ctx.writer.writeAll("\\page\n");
        },
        .rule => {
            try ctx.writer.writeAll("\\pard\\plain\\s1 \\brdrb\\brdrs\\brdrw10\\par\n");
        },
        .toc => {
            try renderToc(ctx, st);
        },
        .script => {},
    }
}

fn renderListItem(ctx: *Ctx, item: ast.ListItem, st: style.Style, ordered: bool, index: usize, depth: usize) RtfError!void {
    const indent_twips: i32 = 360 + @as(i32, @intCast(depth)) * 360;
    try ctx.writer.print("\\pard\\plain\\s8 \\li{d} ", .{indent_twips});
    if (ordered) {
        try ctx.writer.print("{d}. ", .{index});
    } else {
        try ctx.writer.writeAll("\\bullet ");
    }
    try writeInlines(ctx, item.content, .{ .font = fonts.familyFont(st.family, .regular), .size = st.size });
    try ctx.writer.writeAll("\\par\n");
    for (item.children, 1..) |child, i| try renderListItem(ctx, child, st, ordered, i, depth + 1);
}

const RowWriter = struct {
    ctx: *Ctx,
    columns: usize,
    alignments: []const ast.Alignment,
    cellx: []const i32,

    fn row(self: *RowWriter, cells: []const ast.Cell, bold: bool) RtfError!void {
        const st = self.ctx.eng.style;
        try self.ctx.writer.writeAll("\\trowd\\trgaph108\\trleft0");
        for (0..self.columns) |i| try self.ctx.writer.print("\\cellx{d}", .{self.cellx[i]});
        try self.ctx.writer.writeAll("\n");
        for (0..self.columns) |i| {
            const cell = if (i < cells.len) cells[i] else &[_]ast.Inline{};
            const alignment: ast.Alignment = if (i < self.alignments.len) self.alignments[i] else .left;
            try self.ctx.writer.writeAll("\\pard\\intbl\\s1 ");
            try self.ctx.writer.writeAll(switch (alignment) {
                .left => "\\ql ",
                .center => "\\qc ",
                .right => "\\qr ",
            });
            if (bold) try self.ctx.writer.writeAll("\\b1");
            try writeInlines(self.ctx, cell, .{ .font = fonts.familyFont(st.family, .regular), .size = st.size, .bold = bold });
            if (bold) try self.ctx.writer.writeAll("\\b0");
            try self.ctx.writer.writeAll("\\cell\n");
        }
        try self.ctx.writer.writeAll("\\pard\\intbl\\cell\n");
    }
};

fn renderTable(ctx: *Ctx, t: ast.Table, st: style.Style) RtfError!void {
    const columns = @max(t.headers.len, t.rows.len);
    if (columns == 0) return;

    if (t.caption) |cap| try ctx.writer.print("\\pard\\plain\\s10 {s}{s}\\par\n", .{ numberLabel(ctx, t.number), cap });

    var widths = std.array_list.Managed(f64).init(ctx.allocator);
    for (0..columns) |c| {
        var w: f64 = st.size * 2;
        for (t.headers, 0..) |cell, i| {
            if (i != c) continue;
            const m = measureCell(ctx, cell, st);
            if (m > w) w = m;
        }
        for (t.rows) |row| {
            if (row.len <= c) continue;
            const m = measureCell(ctx, row[c], st);
            if (m > w) w = m;
        }
        try widths.append(w);
    }

    const total = st.contentWidth();
    var natural: f64 = 0;
    for (widths.items) |w| natural += w;

    var cellx = std.array_list.Managed(i32).init(ctx.allocator);
    var acc: f64 = 0;
    for (widths.items) |w| {
        acc += w * (total / @max(natural, 1.0));
        try cellx.append(twips(acc));
    }

    var row_writer = RowWriter{ .ctx = ctx, .columns = columns, .alignments = t.alignments, .cellx = cellx.items };
    try row_writer.row(t.headers, true);
    for (t.rows) |row| try row_writer.row(row, false);
}

fn renderToc(ctx: *Ctx, st: style.Style) RtfError!void {
    try ctx.writer.print("\\pard\\plain\\s2 \\b {s}\\par\\pard\\plain\\s1 \\par\n", .{st.toc_title()});
    for (ctx.eng.toc.items) |entry| {
        try ctx.writer.print("\\pard\\plain\\s1 \\li{d} ", .{twips(@as(f64, entry.level) * 18)});
        if (entry.number) |n| try ctx.writer.print("{s} ", .{n});
        try writePlain(ctx, entry.text);
        try ctx.writer.print(" \\tab {d}\\par\n", .{entry.page});
    }
}

fn measureCell(ctx: *Ctx, cell: []const ast.Inline, st: style.Style) f64 {
    return fonts.measure(plainInline(ctx, cell), fonts.familyFont(st.family, .regular), st.size);
}

fn writeInlines(ctx: *Ctx, inlines: []const ast.Inline, base: Fmt) RtfError!void {
    for (inlines) |node| {
        switch (node) {
            .text => |s| try writeRun(ctx, s, base),
            .strong => |kids| try writeInlines(ctx, kids, .{ .font = base.font, .size = base.size, .bold = true, .color = base.color }),
            .em => |kids| try writeInlines(ctx, kids, .{ .font = base.font, .size = base.size, .italic = true, .color = base.color }),
            .code => |s| try writeRun(ctx, s, .{ .font = .courier, .size = ctx.eng.style.code_size, .color = base.color }),
            .link => |l| {
                try ctx.writer.writeAll("{\\field{\\*\\fldinst{HYPERLINK \"");
                try writePlain(ctx, l.url);
                try ctx.writer.writeAll("\"}}{\\fldrslt ");
                try writeInlines(ctx, l.text, .{ .font = base.font, .size = base.size, .color = ctx.eng.style.accent_color, .underline = true });
                try ctx.writer.writeAll("}}");
            },
            .ref => |id| {
                if (ctx.eng.refs.get(id)) |ref| {
                    try writeRun(ctx, ref.number, base);
                    try ctx.writer.print(" (p. {d})", .{ref.page});
                } else {
                    try writeRun(ctx, id, base);
                }
            },
            .cite => |key| {
                const label = std.fmt.allocPrint(ctx.allocator, "[{s}]", .{citeLabel(ctx, key, null)}) catch "";
                try writeRun(ctx, label, .{ .font = base.font, .size = base.size, .color = ctx.eng.style.accent_color, .underline = true });
            },
            .footnote => |kids| {
                ctx.fn_index += 1;
                try ctx.writer.print("{{\\super {d}{{\\footnote ", .{ctx.fn_index});
                try writeInlines(ctx, kids, .{ .font = base.font, .size = ctx.eng.style.footnote_size });
                try ctx.writer.writeAll("}}}");
            },
            .math => |nodes| try writeRun(ctx, plainMathAll(ctx, nodes), .{ .font = base.font, .size = base.size, .italic = true, .color = base.color }),
            .expr => |e| {
                const value = blk: {
                    if (ctx.resolver) |r| break :blk r.evalExpr(e) catch e;
                    break :blk e;
                };
                try writeRun(ctx, value orelse e, base);
            },
            .sup => |kids| {
                try ctx.writer.writeAll("{\\super ");
                try writeInlines(ctx, kids, base);
                try ctx.writer.writeAll("}");
            },
            .sub => |kids| {
                try ctx.writer.writeAll("{\\sub ");
                try writeInlines(ctx, kids, base);
                try ctx.writer.writeAll("}");
            },
        }
    }
}

fn writeRun(ctx: *Ctx, text: []const u8, fmt: Fmt) RtfError!void {
    try ctx.writer.print("{{\\f{d}\\fs{d}", .{ fontIndex(fmt.font), halfPoints(fmt.size) });
    if (fmt.bold) try ctx.writer.writeAll("\\b1");
    if (fmt.italic) try ctx.writer.writeAll("\\i1");
    if (fmt.underline) try ctx.writer.writeAll("\\ul1");
    if (fmt.color) |c| try ctx.writer.print("\\red{d}\\green{d}\\blue{d}", .{
        @as(i32, @intFromFloat(@round(c.r * 255))),
        @as(i32, @intFromFloat(@round(c.g * 255))),
        @as(i32, @intFromFloat(@round(c.b * 255))),
    });
    try writePlain(ctx, text);
    try ctx.writer.writeAll("}");
}

fn writePlain(ctx: *Ctx, text: []const u8) RtfError!void {
    const encoded = cjk.utf8ToRtf(ctx.allocator, text) catch return RtfError.OutOfMemory;
    try ctx.writer.writeAll(encoded);
}

fn plainInline(ctx: *Ctx, inlines: []const ast.Inline) []const u8 {
    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    for (inlines) |node| {
        switch (node) {
            .text, .code, .expr, .ref => |s| buf.appendSlice(s) catch {},
            .strong, .em, .sup, .sub, .footnote => |kids| buf.appendSlice(plainInline(ctx, kids)) catch {},
            .cite => |key| buf.appendSlice(std.fmt.allocPrint(ctx.allocator, "[{s}]", .{citeLabel(ctx, key, null)}) catch "") catch {},
            .link => |l| {
                buf.appendSlice(plainInline(ctx, l.text)) catch {};
                buf.appendSlice(" (") catch {};
                buf.appendSlice(l.url) catch {};
                buf.appendSlice(")") catch {};
            },
            .math => |nodes| buf.appendSlice(plainMathAll(ctx, nodes)) catch {},
        }
    }
    return buf.toOwnedSlice() catch "";
}

fn plainMathAll(ctx: *Ctx, nodes: []const math.Node) []const u8 {
    var buf = std.array_list.Managed(u8).init(ctx.allocator);
    for (nodes) |node| appendMath(ctx, &buf, node) catch {};
    return buf.toOwnedSlice() catch "";
}

fn appendMath(ctx: *Ctx, buf: *std.array_list.Managed(u8), node: math.Node) RtfError!void {
    switch (node) {
        .glyph => |g| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(g.cp, &bytes) catch 0;
            try buf.appendSlice(bytes[0..n]);
        },
        .text => |t| try buf.appendSlice(t),
        .row => |r| {
            for (r) |x| try appendMath(ctx, buf, x);
        },
        .frac => |f| {
            try appendMath(ctx, buf, f.num.*);
            try buf.appendSlice("/");
            try appendMath(ctx, buf, f.denom.*);
        },
        .sqrt => |s| {
            try buf.appendSlice("sqrt(");
            try appendMath(ctx, buf, s.body.*);
            try buf.appendSlice(")");
        },
        .script => |s| {
            try appendMath(ctx, buf, s.base.*);
            if (s.sup) |x| {
                try buf.appendSlice("^(");
                try appendMath(ctx, buf, x.*);
                try buf.appendSlice(")");
            }
            if (s.sub) |x| {
                try buf.appendSlice("_(");
                try appendMath(ctx, buf, x.*);
                try buf.appendSlice(")");
            }
        },
        .over_under => |o| {
            try appendMath(ctx, buf, o.base.*);
            try buf.appendSlice(if (o.above) " ^(" else " _(");
            try appendMath(ctx, buf, o.mark.*);
            try buf.appendSlice(")");
        },
        .tag => |t| try appendMath(ctx, buf, t.body.*),
        .delim => |d| {
            try buf.appendSlice(unicodeChar(d.left));
            try appendMath(ctx, buf, d.body.*);
            try buf.appendSlice(unicodeChar(d.right));
        },
        .matrix => |m| {
            for (m.rows, 0..) |row, i| {
                if (i > 0) try buf.appendSlice(", ");
                for (row) |cell| try appendMath(ctx, buf, cell);
            }
        },
        .cases => |c| {
            for (c.rows, 0..) |row, i| {
                if (i > 0) try buf.appendSlice("; ");
                for (row) |cell| try appendMath(ctx, buf, cell);
            }
        },
        .stack => |s| {
            for (s.items, 0..) |item, i| {
                if (i > 0) try buf.appendSlice(" ");
                try appendMath(ctx, buf, item.*);
            }
        },
        .binom => |b| {
            try appendMath(ctx, buf, b.top.*);
            try buf.appendSlice(" over ");
            try appendMath(ctx, buf, b.bottom.*);
        },
        .space => try buf.appendSlice(" "),
        .rule => try buf.appendSlice("—"),
        .op => |o| try buf.appendSlice(o.name),
        .style => |s| try appendMath(ctx, buf, s.body.*),
        .accent => |a| {
            try appendMath(ctx, buf, a.base.*);
            try buf.appendSlice(unicodeChar(a.cp));
        },
    }
}

fn unicodeChar(cp: u21) []const u8 {
    return std.fmt.allocPrint(std.heap.page_allocator, "{u}", .{cp}) catch "?";
}

fn numberLabel(ctx: *Ctx, number: ?[]const u8) []const u8 {
    if (number) |n| return std.fmt.allocPrint(ctx.allocator, "{s} ", .{n}) catch "";
    return "";
}

fn calloutTitle(kind: ast.CalloutKind) []const u8 {
    return switch (kind) {
        .note => "Note",
        .warning => "Warning",
        .tip => "Tip",
        .caution => "Caution",
        .important => "Important",
    };
}
