//! 排版引擎
//! 负责分行、分页、脚注、目录、计数器与交叉引用。
//! 输出为页 -> 绘制项（文本 run、规则线、矩形、图片），各后端直接消费。

const std = @import("std");
const ast = @import("ast.zig");
const style = @import("style.zig");
const units = @import("units.zig");
const fonts = @import("fonts.zig");
const math = @import("math.zig");
const mathlayout = @import("mathlayout.zig");
const Resolver = @import("resolver.zig").Resolver;
const hyphenate = @import("hyphenate.zig");
const typography = @import("util/typography.zig");
const cjkutil = @import("util/cjk.zig");

fn appendPrint(list: *std.array_list.Managed(u8), comptime fmt: []const u8, args: anytype) LayoutError!void {
    const s = try std.fmt.allocPrint(list.allocator, fmt, args);
    try list.appendSlice(s);
}

pub const Color = style.Color;

/// 显式错误集：避免递归函数之间的推断错误集互相依赖
pub const LayoutError = error{OutOfMemory};

/// TeX 默认断词惩罚
const hyphen_penalty: i32 = 50;
const broken_penalty: i32 = 50;
const forbidden_penalty: i32 = 10000;
/// TeX 的 exhyphenpenalty：已有连字符处断行的惩罚低于断词惩罚
const exhyphen_penalty: i32 = 100;

pub const Item = union(enum) {
    text: TextItem,
    rule: RuleItem,
    rect: RectItem,
    image: ImageItem,
};

pub const TextItem = struct {
    text: []const u8,
    font: fonts.Font,
    size: f64,
    x: f64,
    y: f64, // 基线，y 轴向上
    color: Color,
    link: ?[]const u8 = null,
    scale_x: f64 = 1.0,
    scale_y: f64 = 1.0,
    /// PDF 的 Tc / CSS 的 letter-spacing
    tracking: f64 = 0.0,
};

pub const RuleItem = struct {
    x: f64,
    y: f64,
    w: f64,
    thickness: f64,
    color: Color = Color.black(),
};

pub const RectItem = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    fill: ?Color = null,
    stroke: ?Color = null,
};

pub const ImageItem = struct {
    src: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

pub const Footnote = struct {
    label: []const u8,
    text: []const u8,
    page: usize,
};

pub const Bookmark = struct {
    level: u8,
    title: []const u8,
    page: usize,
};

pub const Ref = struct {
    number: []const u8,
    page: usize,
    key: []const u8 = "",
};

pub const TocEntry = struct {
    level: u8,
    text: []const u8,
    number: ?[]const u8,
    page: usize,
    key: []const u8 = "",
};

pub const Page = struct {
    width: f64,
    height: f64,
    margins: units.Margins,
    number: usize = 1,
    /// 页码显示文本（按页码样式格式化，例如 xii）
    label: []const u8 = "",
    backgrounds: std.array_list.Managed(RectItem),
    items: std.array_list.Managed(Item),
    header: std.array_list.Managed(Item),
    footer: std.array_list.Managed(Item),
    footnotes: std.array_list.Managed(Footnote),
    bookmarks: std.array_list.Managed(Bookmark),

    fn init(allocator: std.mem.Allocator, number: usize, w: f64, h: f64, margins: units.Margins) Page {
        return .{
            .width = w,
            .height = h,
            .margins = margins,
            .number = number,
            .backgrounds = std.array_list.Managed(RectItem).init(allocator),
            .items = std.array_list.Managed(Item).init(allocator),
            .header = std.array_list.Managed(Item).init(allocator),
            .footer = std.array_list.Managed(Item).init(allocator),
            .footnotes = std.array_list.Managed(Footnote).init(allocator),
            .bookmarks = std.array_list.Managed(Bookmark).init(allocator),
        };
    }
};

// ---------------------------------------------------------------- 行模型

pub const Token = struct {
    kind: Kind,
    text: []const u8 = "",
    font: fonts.Font = .helvetica,
    size: f64 = 10,
    color: Color = Color.black(),
    link: ?[]const u8 = null,
    underline: bool = false,
    y_offset: f64 = 0,
    width: f64 = 0,
    h: f64 = 0,
    d: f64 = 0,
    box: ?mathlayout.Box = null,
    glue: f64 = 0,
    breakable: bool = false,
    hanging: bool = false,
    footnote: ?usize = null,
    /// 断行惩罚：0 为普通断点，负值表示优先，10000 表示禁止
    penalty: i32 = 0,
    /// 该 run 的字距（每个字形后追加的空隙），已计入 width
    tracking: f64 = 0.0,
    /// 可伸缩度（TeX：普通空格 1，行末 glue 0.5，断词 2）
    adjustability: f64 = 0,
    /// 字形突入边距的量（hanging punctuation / optical margin）
    hang_left: f64 = 0,
    hang_right: f64 = 0,
    /// 该 token 是 discretionary hyphen（只在断行时出现）
    discretionary: bool = false,
    /// CJK 行首禁则：该 token 前不允许断行（闭标点不能出现在行首）
    no_break_before: bool = false,
    /// CJK 行末禁则：该 token 后不允许断行（开标点不能出现在行末）
    no_break_after: bool = false,

    pub const Kind = enum { run, box, glue, discretionary };
};

pub const Marker = struct {
    text: []const u8,
    font: fonts.Font,
    size: f64,
    color: Color,
    /// 标记占用的悬挂宽度：正文从 left 开始，标记绘制在 left - width
    width: f64,
};

/// display 公式断行时的一段：以关系符开头的段左边缘就是对齐点
const MathPart = struct {
    nodes: []math.Node,
    box: mathlayout.Box,
    first_class: math.TexClass,
    last_class: math.TexClass,
    aligned: bool,
};

pub const Line = struct {
    tokens: []Token,
    glue: []usize,
    natural: f64,
    height: f64,
    depth: f64,
    last: bool = false,
    /// 行尾因断词产生连字符
    hyphenated: bool = false,
    /// 首尾字形突入边距的量
    hang_left: f64 = 0,
    hang_right: f64 = 0,
};

// ---------------------------------------------------------------- 引擎

pub const Engine = struct {
    allocator: std.mem.Allocator,
    doc: *ast.Document,
    style: style.Style,
    resolver: ?*const Resolver = null,
    refs: std.StringHashMap(Ref),
    pages: std.array_list.Managed(Page),
    footnotes: std.array_list.Managed(Footnote),
    toc: std.array_list.Managed(TocEntry),
    math_layout: mathlayout.Layout,
    heading_pages: std.StringHashMap(usize),
    hyphen_table: hyphenate.Table,

    cursor: f64 = 0,
    top_limit: f64 = 0,
    bottom_limit: f64 = 0,
    footnote_reserve: f64 = 0,
    page_footnotes: std.array_list.Managed(usize),
    /// 当前栏放不下、顺延到下一栏/下一页的脚注
    pending_footnotes: std.array_list.Managed(usize),
    /// 布局时递增的脚注游标：footnotes 表在编号阶段已预填充，不能用长度当下标
    footnote_cursor: usize = 0,
    /// 当前栏序号（多栏排版）
    column: usize = 0,
    /// 最近一次出现的标题文本，用于 {{section}} 运行标题
    current_section: []const u8 = "",
    /// 引用（文献）游标
    citation_cursor: usize = 0,
    /// 当前作用域是否允许断词：标题、代码、表格单元格等关闭断词
    allow_hyphen: bool = true,
    /// 当前作用域的字距（letter-spacing）：正文用 style.tracking，标题用 heading_tracking
    current_tracking: f64 = 0.0,
    /// 布局是否已到达文档末尾：末尾不再顺延脚注
    at_end: bool = false,

    counters: Counters = Counters{},

    const Counters = struct {
        section: [6]usize = .{ 0, 0, 0, 0, 0, 0 },
        figure: usize = 0,
        table: usize = 0,
        listing: usize = 0,
        equation: usize = 0,
        footnote: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, doc: *ast.Document, st: style.Style, resolver: ?*const Resolver) Engine {
        var e = Engine{
            .allocator = allocator,
            .doc = doc,
            .style = st,
            .resolver = resolver,
            .refs = std.StringHashMap(Ref).init(allocator),
            .pages = std.array_list.Managed(Page).init(allocator),
            .footnotes = std.array_list.Managed(Footnote).init(allocator),
            .toc = std.array_list.Managed(TocEntry).init(allocator),
            .math_layout = mathlayout.Layout.init(allocator, st.family),
            .heading_pages = std.StringHashMap(usize).init(allocator),
            .page_footnotes = std.array_list.Managed(usize).init(allocator),
            .hyphen_table = hyphenate.Table.init(allocator) catch hyphenate.Table.init(std.heap.page_allocator) catch unreachable,
            .pending_footnotes = std.array_list.Managed(usize).init(allocator),
        };
        e.top_limit = st.paper.height - st.margins.top - headerSpace(st);
        e.bottom_limit = st.margins.bottom + footerSpace(st);
        e.current_tracking = st.tracking;
        return e;
    }

    fn headerSpace(st: style.Style) f64 {
        if (st.header_left == null and st.header_center == null and st.header_right == null) return 0;
        return st.header_size + 14;
    }

    fn footerSpace(st: style.Style) f64 {
        if (st.footer_left == null and st.footer_center == null and st.footer_right == null) return 0;
        return st.header_size + 14;
    }

    // ---- 多栏 ----

    /// 临时改变断词开关，返回之前的值（调用方负责恢复）
    fn withHyphen(self: *Engine, allow: bool) bool {
        const prev = self.allow_hyphen;
        self.allow_hyphen = allow;
        return prev;
    }

    /// 临时改变字距，返回之前的值（调用方负责恢复）
    fn withTracking(self: *Engine, value: f64) f64 {
        const prev = self.current_tracking;
        self.current_tracking = value;
        return prev;
    }

    fn colWidth(self: *Engine) f64 {
        return self.style.columnWidth();
    }

    fn colOffset(self: *Engine) f64 {
        if (self.style.columns <= 1) return 0;
        return @as(f64, @floatFromInt(self.column)) * (self.style.columnWidth() + self.style.column_gap);
    }

    /// 把基于左边距的坐标换算到当前栏
    fn colX(self: *Engine, x: f64) f64 {
        return x + self.colOffset();
    }

    /// 完整排版：先编号，再分页。含目录时迭代重排，直到目录页码收敛
    pub fn run(self: *Engine) LayoutError![]Page {
        try self.numberPass();
        if (!self.needsToc()) return try self.layoutPass();

        var result: []Page = &.{};
        var iter: usize = 0;
        while (iter < 4) : (iter += 1) {
            const pages = try self.layoutPass();
            const snapshot = try self.snapshotTocPages();
            if (iter > 0) {
                var stable = true;
                for (self.toc.items, 0..) |entry, i| {
                    if (snapshot[i] != entry.page) {
                        stable = false;
                        break;
                    }
                }
                result = pages;
                if (stable) return pages;
            } else {
                result = pages;
            }
            for (snapshot, 0..) |p, i| {
                const entry = self.toc.items[i];
                if (entry.key.len == 0) continue;
                try self.heading_pages.put(entry.key, p);
            }
            try self.resetLayout();
        }
        return result;
    }

    fn needsToc(self: *Engine) bool {
        if (self.style.toc) return true;
        for (self.doc.content) |block| {
            if (block == .toc) return true;
        }
        return false;
    }

    fn snapshotTocPages(self: *Engine) LayoutError![]usize {
        var out = std.array_list.Managed(usize).init(self.allocator);
        for (self.toc.items) |entry| try out.append(entry.page);
        return out.toOwnedSlice();
    }

    fn resetLayout(self: *Engine) LayoutError!void {
        self.pages = std.array_list.Managed(Page).init(self.allocator);
        self.toc = std.array_list.Managed(TocEntry).init(self.allocator);
        self.footnotes = std.array_list.Managed(Footnote).init(self.allocator);
        self.page_footnotes = std.array_list.Managed(usize).init(self.allocator);
        self.pending_footnotes = std.array_list.Managed(usize).init(self.allocator);
        self.refs = std.StringHashMap(Ref).init(self.allocator);
        self.footnote_cursor = 0;
        self.counters = Counters{};
        try self.numberPass();
    }

    // ---- 编号与脚注收集 ----

    fn numberPass(self: *Engine) LayoutError!void {
        try self.citationPass();
        for (self.doc.content) |*block| try self.numberBlock(block);
    }

    /// 引文编号：先按正文中出现的顺序编号，未被引用的条目按文献表顺序续编号
    fn citationPass(self: *Engine) LayoutError!void {
        var order = std.array_list.Managed([]const u8).init(self.allocator);
        var seen = std.StringHashMap(bool).init(self.allocator);
        for (self.doc.content) |block| try self.collectCitations(block, &order, &seen);

        for (order.items, 0..) |key, i| {
            try self.refs.put(key, .{
                .number = try std.fmt.allocPrint(self.allocator, "{d}", .{i + 1}),
                .page = 0,
                .key = key,
            });
        }

        var next: usize = order.items.len;
        for (self.doc.content) |block| {
            if (block != .bibliography) continue;
            for (block.bibliography.entries) |entry| {
                if (seen.get(entry.key) != null) continue;
                next += 1;
                try self.refs.put(entry.key, .{
                    .number = try std.fmt.allocPrint(self.allocator, "{d}", .{next}),
                    .page = 0,
                    .key = entry.key,
                });
            }
        }
    }

    fn collectCitations(self: *Engine, block: ast.Block, order: *std.array_list.Managed([]const u8), seen: *std.StringHashMap(bool)) LayoutError!void {
        switch (block) {
            .heading => |h| try self.collectCitationInlines(h.text, order, seen),
            .paragraph => |p| try self.collectCitationInlines(p.content, order, seen),
            .list => |l| {
                for (l.items) |item| {
                    try self.collectCitationInlines(item.content, order, seen);
                    for (item.children) |child| try self.collectCitationInlines(child.content, order, seen);
                }
            },
            .quote => |q| {
                for (q.content) |b| try self.collectCitations(b, order, seen);
            },
            .callout => |c| {
                for (c.content) |b| try self.collectCitations(b, order, seen);
            },
            .table => |t| {
                for (t.headers) |cell| try self.collectCitationInlines(cell, order, seen);
                for (t.rows) |row| for (row) |cell| try self.collectCitationInlines(cell, order, seen);
            },
            .definition_list => |d| {
                for (d.entries) |entry| {
                    try self.collectCitationInlines(entry.term, order, seen);
                    try self.collectCitationInlines(entry.definition, order, seen);
                }
            },
            .bibliography => |b| {
                for (b.entries) |entry| try self.collectCitationInlines(entry.text, order, seen);
            },
            else => {},
        }
    }

    fn collectCitationInlines(self: *Engine, inlines: []const ast.Inline, order: *std.array_list.Managed([]const u8), seen: *std.StringHashMap(bool)) LayoutError!void {
        for (inlines) |node| {
            switch (node) {
                .cite => |key| {
                    if (seen.get(key) != null) continue;
                    try seen.put(key, true);
                    try order.append(try self.allocator.dupe(u8, key));
                },
                .strong, .em, .sup, .sub => |kids| try self.collectCitationInlines(kids, order, seen),
                .link => |l| try self.collectCitationInlines(l.text, order, seen),
                .footnote => |kids| try self.collectCitationInlines(kids, order, seen),
                else => {},
            }
        }
    }

    fn numberBlock(self: *Engine, block: *ast.Block) LayoutError!void {
        switch (block.*) {
            .heading => |*h| {
                if (self.style.heading_autonumber) {
                    const level = h.level;
                    self.counters.section[level - 1] += 1;
                    for (level..6) |i| self.counters.section[i] = 0;
                    h.number = try self.sectionNumber(level);
                }
                try self.collectInlines(h.text);
                if (h.id) |id| try self.refs.put(id, .{ .number = h.number orelse "", .page = 0, .key = try self.allocator.dupe(u8, id) });
            },
            .paragraph => |p| try self.collectInlines(p.content),
            .list => |l| {
                for (l.items) |item| {
                    try self.collectInlines(item.content);
                    for (item.children) |child| try self.collectInlines(child.content);
                }
            },
            .quote => |q| {
                for (q.content) |*b| try self.numberBlock(b);
            },
            .callout => |c| {
                for (c.content) |*b| try self.numberBlock(b);
            },
            .code => |*c| {
                if (c.caption != null or c.id != null) {
                    self.counters.listing += 1;
                    c.number = try self.formatNumber(self.style.listing_label(), self.counters.listing);
                }
                if (c.id) |id| try self.refs.put(id, .{ .number = c.number orelse "", .page = 0, .key = try self.allocator.dupe(u8, id) });
            },
            .figure => |*f| {
                if (f.caption != null or f.id != null) {
                    self.counters.figure += 1;
                    f.number = try self.formatNumber(self.style.figure_label(), self.counters.figure);
                }
                if (f.id) |id| try self.refs.put(id, .{ .number = f.number orelse "", .page = 0, .key = try self.allocator.dupe(u8, id) });
            },
            .table => |*t| {
                if (t.caption != null or t.id != null) {
                    self.counters.table += 1;
                    t.number = try self.formatNumber(self.style.table_label(), self.counters.table);
                }
                if (t.id) |id| try self.refs.put(id, .{ .number = t.number orelse "", .page = 0, .key = try self.allocator.dupe(u8, id) });
            },
            .math => |*m| {
                const tag = mathTag(m.nodes);
                if (tag) |t| {
                    // Typst：tag(...) 用标签内容替代自动编号，notag() 则完全不编号
                    if (!t.suppress) {
                        const s = try self.mathPlainText(t.body.*);
                        if (s.len > 0) m.number = s;
                    }
                } else if (self.style.numbering) {
                    self.counters.equation += 1;
                    m.number = try std.fmt.allocPrint(self.allocator, "({d})", .{self.counters.equation});
                }
                if (m.id) |id| try self.refs.put(id, .{ .number = m.number orelse "", .page = 0, .key = try self.allocator.dupe(u8, id) });
            },
            .definition_list => |d| {
                for (d.entries) |entry| {
                    try self.collectInlines(entry.term);
                    try self.collectInlines(entry.definition);
                }
            },
            else => {},
        }
    }

    fn sectionNumber(self: *Engine, level: u8) LayoutError![]const u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        for (0..level) |i| {
            if (i > 0) try out.append('.');
            try out.appendSlice(try std.fmt.allocPrint(self.allocator, "{d}", .{self.counters.section[i]}));
        }
        return out.toOwnedSlice();
    }

    fn formatNumber(self: *Engine, label: []const u8, n: usize) LayoutError![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{s} {d}", .{ label, n });
    }

    fn collectInlines(self: *Engine, inlines: []const ast.Inline) LayoutError!void {
        for (inlines) |node| {
            switch (node) {
                .strong, .em, .sup, .sub => |kids| try self.collectInlines(kids),
                .link => |l| try self.collectInlines(l.text),
                .footnote => |kids| {
                    self.counters.footnote += 1;
                    const label = try std.fmt.allocPrint(self.allocator, "{d}", .{self.counters.footnote});
                    const text = try self.inlinePlainText(kids);
                    try self.footnotes.append(.{ .label = label, .text = text, .page = 0 });
                    try self.collectInlines(kids);
                },
                else => {},
            }
        }
    }

    fn inlinePlainText(self: *Engine, inlines: []const ast.Inline) LayoutError![]const u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        for (inlines) |node| {
            switch (node) {
                .text => |s| try out.appendSlice(s),
                .code => |s| try out.appendSlice(s),
                .strong, .em, .sup, .sub => |kids| try out.appendSlice(try self.inlinePlainText(kids)),
                .link => |l| {
                    try out.appendSlice(try self.inlinePlainText(l.text));
                    try out.appendSlice(" (");
                    try out.appendSlice(l.url);
                    try out.appendSlice(")");
                },
                .math => |nodes| {
                    for (nodes) |n| try out.appendSlice(try self.nodePlainText(n));
                },
                .expr => |s| {
                    if (self.resolver) |r| {
                        const v = r.evalExpr(s) catch null;
                        try out.appendSlice(v orelse s);
                    } else {
                        try out.appendSlice(s);
                    }
                },
                .ref => |id| {
                    const r = self.refs.get(id) orelse Ref{ .number = "", .page = 0, .key = id };
                    if (r.number.len > 0) try out.appendSlice(r.number) else try out.appendSlice(id);
                },
                .footnote => |kids| try out.appendSlice(try self.inlinePlainText(kids)),
                .cite => |key| {
                    const r = self.refs.get(key);
                    if (r != null and r.?.number.len > 0) try out.appendSlice(r.?.number) else try out.appendSlice(key);
                },
            }
        }
        return out.toOwnedSlice();
    }

    fn nodePlainText(self: *Engine, node: math.Node) LayoutError![]const u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        switch (node) {
            .glyph => |g| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(g.cp, &buf) catch 0;
                try out.appendSlice(buf[0..n]);
            },
            .text => |t| try out.appendSlice(t),
            .row => |r| {
                for (r) |x| try out.appendSlice(try self.nodePlainText(x));
            },
            .frac => |f| {
                try out.appendSlice(try self.nodePlainText(f.num.*));
                try out.appendSlice("/");
                try out.appendSlice(try self.nodePlainText(f.denom.*));
            },
            .script => |s| {
                try out.appendSlice(try self.nodePlainText(s.base.*));
                if (s.sup) |x| {
                    try out.appendSlice("^");
                    try out.appendSlice(try self.nodePlainText(x.*));
                }
                if (s.sub) |x| {
                    try out.appendSlice("_");
                    try out.appendSlice(try self.nodePlainText(x.*));
                }
            },
            else => try out.appendSlice("(formula)"),
        }
        return out.toOwnedSlice();
    }

    // ---- 分页 ----

    fn layoutPass(self: *Engine) LayoutError![]Page {
        self.cursor = self.top_limit;
        self.footnote_reserve = 0;
        self.page_footnotes = std.array_list.Managed(usize).init(self.allocator);
        self.pending_footnotes = std.array_list.Managed(usize).init(self.allocator);
        self.at_end = false;
        try self.newPage();
        for (self.doc.content) |block| try self.placeBlock(block);
        self.at_end = true;
        try self.finishPage();
        return self.pages.toOwnedSlice();
    }

    fn newPage(self: *Engine) LayoutError!void {
        const number = self.pages.items.len + 1;
        var page = Page.init(
            self.allocator,
            number,
            self.style.paper.width,
            self.style.paper.height,
            self.style.margins,
        );
        page.label = style.formatNumber(self.numberStyleFor(number), number, self.allocator);
        try self.pages.append(page);
        self.column = 0;
        self.cursor = self.top_limit;
        self.adoptPendingFootnotes();
    }

    fn numberStyleFor(self: *Engine, number: usize) style.NumberStyle {
        if (self.style.front_matter_depth > 0 and number <= self.style.front_matter_depth) {
            return self.style.front_number_style;
        }
        return self.style.page_number_style;
    }

    fn currentPage(self: *Engine) *Page {
        return &self.pages.items[self.pages.items.len - 1];
    }

    fn available(self: *Engine) f64 {
        return self.cursor - self.bottom_limit - self.footnote_reserve;
    }

    fn breakPage(self: *Engine) LayoutError!void {
        try self.finishColumn();
        try self.finishPage();
        try self.newPage();
    }

    /// 多栏排版：先填满当前栏，最后一栏填满才翻页
    fn breakColumn(self: *Engine) LayoutError!void {
        const st = self.style;
        if (st.columns > 1 and self.column + 1 < st.columns) {
            try self.finishColumn();
            self.column += 1;
            self.cursor = self.top_limit;
            self.adoptPendingFootnotes();
            return;
        }
        try self.breakPage();
    }

    fn finishColumn(self: *Engine) LayoutError!void {
        const page = self.currentPage();
        const st = self.style;
        if (self.page_footnotes.items.len == 0) return;

        const needed = self.footnoteBlockHeight(self.page_footnotes.items);
        // 放不下就整组顺延到下一栏/下一页；单组脚注本身超过整栏高度时只能就地排下
        if (!self.at_end and self.cursor < self.bottom_limit + needed and
            needed < self.top_limit - self.bottom_limit)
        {
            for (self.page_footnotes.items) |idx| try self.pending_footnotes.append(idx);
            self.page_footnotes = std.array_list.Managed(usize).init(self.allocator);
            self.footnote_reserve = 0;
            return;
        }

        const rule_y = self.bottom_limit + self.footnote_reserve;
        try page.items.append(.{ .rule = .{
            .x = self.colX(st.margins.left),
            .y = rule_y,
            .w = self.colWidth(),
            .thickness = 0.4,
            .color = st.muted_color,
        } });

        var y = rule_y - st.footnote_size * 0.8;
        for (self.page_footnotes.items) |idx| {
            const fnote = self.footnotes.items[idx];
            const entry = Footnote{ .label = fnote.label, .text = fnote.text, .page = page.number };
            self.footnotes.items[idx] = entry;
            try page.footnotes.append(entry);
            var tokens = std.array_list.Managed(Token).init(self.allocator);
            try tokens.append(Token{
                .kind = .run,
                .text = fnote.label,
                .font = fonts.familyFont(st.family, .regular),
                .size = st.footnote_size,
                .color = st.muted_color,
                .width = fonts.measure(fnote.label, fonts.familyFont(st.family, .regular), st.footnote_size),
                .h = fonts.ascent(fonts.familyFont(st.family, .regular), st.footnote_size),
                .d = fonts.descent(fonts.familyFont(st.family, .regular), st.footnote_size),
            });
            try tokens.append(Token{ .kind = .glue, .glue = st.footnote_size * 0.3, .adjustability = 1.0 });
            try self.pushText(&tokens, fnote.text, st.footnote_size, st.family, .regular, st.muted_color, null, false);
            const lines = try self.breakTokens(tokens.items, self.colWidth() - st.footnote_size * 1.6);
            for (lines) |line| {
                try self.emitLine(line, self.colX(st.margins.left) + st.footnote_size * 1.6, y, false, self.colWidth() - st.footnote_size * 1.6);
                y -= @max(st.footnote_size * 1.35, line.height + line.depth);
            }
        }
        // 画完即清空：同一页可能被 finishColumn 两次（breakColumn 回落到 breakPage 时）
        self.page_footnotes = std.array_list.Managed(usize).init(self.allocator);
        self.footnote_reserve = 0;
    }

    fn finishPage(self: *Engine) LayoutError!void {
        try self.finishColumn();
        try self.renderHeaderFooter(self.currentPage());
    }

    /// 一组脚注在栏底占用的高度（含分隔线与行距）
    fn footnoteBlockHeight(self: *Engine, indices: []const usize) f64 {
        const st = self.style;
        const measure = self.colWidth() - st.footnote_size * 1.6;
        var total: f64 = 0;
        for (indices) |idx| {
            const lines = estimateLines(self.footnotes.items[idx].text, measure, st.footnote_size, st.family);
            total += @as(f64, @floatFromInt(lines)) * st.footnote_size * 1.35 + st.footnote_size * 0.4;
        }
        return total;
    }

    /// 把上一栏顺延的脚注接到当前栏，并预留相应高度
    fn adoptPendingFootnotes(self: *Engine) void {
        self.page_footnotes = self.pending_footnotes;
        self.pending_footnotes = std.array_list.Managed(usize).init(self.allocator);
        self.footnote_reserve = self.footnoteBlockHeight(self.page_footnotes.items);
    }

    fn renderHeaderFooter(self: *Engine, page: *Page) LayoutError!void {
        const st = self.style;
        const total = self.pages.items.len;
        var header = std.array_list.Managed(Item).init(self.allocator);
        var footer = std.array_list.Managed(Item).init(self.allocator);
        if (st.plain_first_page and page.number == 1) return;
        const font = fonts.familyFont(st.family, .regular);
        const y_header = st.paper.height - st.margins.top + 14;
        const y_footer = st.margins.bottom - 10;

        const parts = [_]struct { value: ?[]const u8, y: f64, alignment: usize }{
            .{ .value = st.header_left, .y = y_header, .alignment = 0 },
            .{ .value = st.header_center, .y = y_header, .alignment = 1 },
            .{ .value = st.header_right, .y = y_header, .alignment = 2 },
            .{ .value = st.footer_left, .y = y_footer, .alignment = 0 },
            .{ .value = st.footer_center, .y = y_footer, .alignment = 1 },
            .{ .value = st.footer_right, .y = y_footer, .alignment = 2 },
        };

        for (parts) |part| {
            const raw = part.value orelse continue;
            const text = try self.expandTemplate(raw, page, total);
            const w = fonts.measure(text, font, st.header_size);
            const x = switch (part.alignment) {
                0 => st.margins.left,
                1 => st.margins.left + (st.contentWidth() - w) / 2.0,
                else => st.margins.left + st.contentWidth() - w,
            };
            const target = if (part.y > st.paper.height / 2.0) &header else &footer;
            try target.append(.{ .text = .{
                .text = text,
                .font = font,
                .size = st.header_size,
                .x = x,
                .y = part.y,
                .color = st.muted_color,
            } });
        }
        try page.header.appendSlice(header.items);
        try page.footer.appendSlice(footer.items);
    }

    fn expandTemplate(self: *Engine, raw: []const u8, page: *Page, total: usize) LayoutError![]const u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        var i: usize = 0;
        while (i < raw.len) {
            if (std.mem.startsWith(u8, raw[i..], "{{page}}")) {
                try out.appendSlice(page.label);
                i += 8;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "{{section}}")) {
                try out.appendSlice(self.current_section);
                i += 11;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "{{pages}}")) {
                try appendPrint(&out, "{d}", .{total});
                i += 9;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "{{title}}")) {
                try out.appendSlice(self.doc.metadata.getOr("title", ""));
                i += 9;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "{{author}}")) {
                try out.appendSlice(self.doc.metadata.getOr("author", ""));
                i += 10;
                continue;
            }
            if (std.mem.startsWith(u8, raw[i..], "{{date}}")) {
                try out.appendSlice(self.doc.metadata.getOr("date", ""));
                i += 8;
                continue;
            }
            try out.append(raw[i]);
            i += 1;
        }
        return out.toOwnedSlice();
    }

    // ---- 块放置 ----

    fn placeBlock(self: *Engine, block: ast.Block) LayoutError!void {
        switch (block) {
            .heading => |h| try self.placeHeading(h),
            .paragraph => |p| try self.placeParagraph(p),
            .list => |l| try self.placeList(l, 0),
            .quote => |q| try self.placeQuote(q),
            .code => |c| try self.placeCode(c),
            .figure => |f| try self.placeFigure(f),
            .table => |t| try self.placeTable(t),
            .callout => |c| try self.placeCallout(c),
            .math => |m| try self.placeMathBlock(m),
            .definition_list => |d| try self.placeDefinitionList(d),
            .bibliography => |b| try self.placeBibliography(b),
            .page_break => try self.breakPage(),
            .column_break => try self.breakColumn(),
            .rule => try self.placeRule(),
            .toc => try self.placeToc(),
            .script => {},
        }
    }

    fn placeHeading(self: *Engine, h: ast.Heading) LayoutError!void {
        const st = self.style;
        const level = h.level;
        const size = st.heading_sizes[level - 1];
        // 标题不断词（Typst 行为）
        const prev_hyphen = self.withHyphen(false);
        // 大字号标题收紧字距（负 tracking），小标题保持正文字距
        const prev_tracking = self.withTracking(if (level <= 2) st.heading_tracking else st.tracking);
        const tokens = try self.tokensFromInlines(h.text, size, st.heading_family, st.text_color);
        const lines = try self.breakTokens(tokens, self.colWidth());
        self.allow_hyphen = prev_hyphen;
        self.current_tracking = prev_tracking;

        // 标题必须与后续内容留在同一页：至少保留标题本身加一行后续内容
        const first_line = if (lines.len > 0) @max(size * 1.25, lines[0].height + lines[0].depth) else size * 1.25;
        const keep_next = st.heading_before[level - 1] + first_line + st.heading_after[level - 1] + st.leading;
        if (self.cursor - keep_next < self.bottom_limit) try self.breakColumn();
        self.cursor -= st.heading_before[level - 1];

        for (lines) |line| {
            const needed = @max(size * 1.25, line.height + line.depth);
            if (self.cursor - needed < self.bottom_limit) try self.breakColumn();
            const baseline = self.cursor - @max(0, (needed - (line.height + line.depth)) / 2.0) - line.height;
            try self.emitLine(line, self.colX(st.margins.left), baseline, false, self.colWidth());
            self.cursor -= needed;
        }
        self.cursor -= st.heading_after[level - 1];

        const title = try self.inlinePlainText(h.text);
        self.current_section = title;
        try self.currentPage().bookmarks.append(.{ .level = level, .title = title, .page = self.currentPage().number });
        if (h.id) |id| {
            const r = self.refs.get(id) orelse Ref{ .number = "", .page = 0, .key = id };
            try self.refs.put(id, .{ .number = if (r.number.len > 0) r.number else (h.number orelse ""), .page = self.currentPage().number, .key = r.key });
        }
        if (self.style.toc and level <= self.style.toc_depth) {
            try self.toc.append(TocEntry{
                .level = level,
                .text = title,
                .number = h.number,
                .page = self.currentPage().number,
            });
        }
    }

    fn placeParagraph(self: *Engine, p: ast.Paragraph) LayoutError!void {
        const st = self.style;
        const tokens = try self.tokensFromInlines(p.content, st.size, st.family, st.text_color);
        const lines = try self.breakTokens(tokens, self.colWidth());
        try self.placeLines(lines, 0, st.indent, st.justify, null, self.colWidth());
        self.cursor -= st.parskip;
    }

    /// measure 是这段文字实际可用的宽度：缩进块（引用、清单、提示框）不能按整栏宽度对齐
    fn placeLines(self: *Engine, lines: []Line, offset: f64, first_indent: f64, justify: bool, marker: ?Marker, measure: f64) LayoutError!void {
        const st = self.style;
        if (lines.len == 0) return;

        // 整块放不下时先分页
        if (self.available() <= 0) try self.breakColumn();

        // 先算出当前页能容纳多少行，再应用孤行/寡行/club 控制
        var fit: usize = 0;
        var probe = self.cursor;
        var probe_depth: f64 = 0;
        for (lines) |line| {
            const needed = @max(st.leading, line.height + probe_depth + st.lineskip);
            if (probe - needed < self.bottom_limit + self.footnote_reserve) break;
            fit += 1;
            probe -= needed;
            probe_depth = line.depth;
        }
        if (lines.len > st.orphans + st.widows) {
            if (fit < st.orphans) {
                // 孤行：本页放不下 orphans 行 -> 整段移到下一页
                fit = 0;
            } else if (lines.len - fit < st.widows) {
                // 寡行：单独出现在下一页的行太少 -> 少放几行，让段末一起走
                fit = lines.len - st.widows;
            }
        }
        if (fit == 0) try self.breakColumn();

        // TeX 的行距模型：基线到基线 = max(baselineskip, 上一行深度 + 本行高度 + lineskip)。
        // 首行仍按现代排版在行盒内居中；只有行盒相碰（混合字号、公式）时才额外产生间隙。
        var prev_baseline: ?f64 = null;
        var prev_depth: f64 = 0;

        for (lines, 0..) |line, i| {
            if (i > 0 and i == fit) {
                try self.breakColumn();
                prev_baseline = null;
                prev_depth = 0;
            }
            const span = @max(st.leading, line.height + prev_depth + st.lineskip);
            // 单行比整页剩余空间还高：允许溢出，避免死循环
            if (prev_baseline == null) {
                if (self.cursor - span < self.bottom_limit + self.footnote_reserve and self.cursor < self.top_limit) {
                    try self.breakColumn();
                }
            } else if (prev_baseline.? - span + line.depth < self.bottom_limit + self.footnote_reserve) {
                try self.breakColumn();
            }
            if (self.cursor >= self.top_limit) {
                // 换页/换栏后重新起算：上一行的深度不再参与
                prev_baseline = null;
                prev_depth = 0;
            }
            const indent = if (i == 0) first_indent else 0;
            const top = self.cursor;
            var baseline: f64 = 0;
            if (prev_baseline == null) {
                const half = @max(0.0, (st.leading - (line.height + line.depth)) / 2.0);
                baseline = top - half - line.height;
            } else {
                baseline = prev_baseline.? - span;
            }
            // 每行按当前栏计算左边界：跨栏时正文与标记仍然对齐
            const left = self.colX(st.margins.left) + offset;
            if (i == 0 and marker != null) {
                const m = marker.?;
                try self.currentPage().items.append(.{ .text = .{
                    .text = m.text,
                    .font = m.font,
                    .size = m.size,
                    .x = left - m.width,
                    .y = baseline,
                    .color = m.color,
                } });
            }
            try self.emitLine(line, left + indent, baseline, justify and !line.last, measure);
            prev_baseline = baseline;
            prev_depth = line.depth;
            self.cursor -= span;
        }
    }

    fn emitLine(self: *Engine, line: Line, left: f64, baseline: f64, justify: bool, measure: f64) LayoutError!void {
        const st = self.style;
        const page = self.currentPage();

        // 两端对齐：把多余宽度按各 glue 的可伸缩度比例分配（TeX 风格），
        // 而不是平均分摊，这样窄空格不会被拉得比宽空格更夸张。
        var extra: f64 = 0;
        var total_adj: f64 = 0;
        if (justify and line.glue.len > 0) {
            for (line.glue) |gi| total_adj += line.tokens[gi].adjustability;
            if (total_adj <= 0) total_adj = @as(f64, @floatFromInt(line.glue.len));
            extra = (measure - line.hang_left - line.hang_right - line.natural) / total_adj;
            if (extra < -0.30 * st.size) extra = -0.30 * st.size; // 最大压缩
            if (extra > 0.15 * st.size) extra = 0.15 * st.size; // 最大拉伸
        }

        // 悬挂标点：首字突入左边距（optical margin）
        var x = left - line.hang_left;
        var leading = true;
        for (line.tokens, 0..) |t, i| {
            if (leading and t.kind == .glue) continue;
            leading = false;
            switch (t.kind) {
                .glue => {
                    x += t.glue + extra * t.adjustability;
                },
                .discretionary => {
                    // discretionary hyphen 只在真正断行的位置出现（即行尾）
                    if (i == line.tokens.len - 1) {
                        try page.items.append(.{ .text = .{
                            .text = t.text,
                            .font = t.font,
                            .size = t.size,
                            .x = x,
                            .y = baseline + t.y_offset,
                            .color = t.color,
                            .link = t.link,
                        } });
                    }
                    x += t.width + extra * t.adjustability;
                },
                .run => {
                    if (t.width > 0) {
                        try page.items.append(.{ .text = .{
                            .text = t.text,
                            .font = t.font,
                            .size = t.size,
                            .x = x,
                            .y = baseline + t.y_offset,
                            .color = t.color,
                            .link = t.link,
                            .tracking = t.tracking,
                        } });
                        if (t.underline) {
                            try page.items.append(.{ .rule = .{
                                .x = x,
                                .y = baseline + t.y_offset - t.size * 0.12,
                                .w = t.width,
                                .thickness = 0.5,
                                .color = t.color,
                            } });
                        }
                    }
                    if (t.footnote) |idx| {
                        const fnote = self.footnotes.items[idx];
                        try self.page_footnotes.append(idx);
                        const lines_needed = estimateLines(fnote.text, self.colWidth() - st.footnote_size * 1.6, st.footnote_size, st.family);
                        self.footnote_reserve += @as(f64, @floatFromInt(lines_needed)) * st.footnote_size * 1.35 + st.footnote_size * 0.4;
                    }
                    x += t.width;
                },
                .box => {
                    const b = t.box.?;
                    for (b.items) |mi| {
                        switch (mi) {
                            .text => |mt| try page.items.append(.{ .text = .{
                                .text = mt.text,
                                .font = mt.font,
                                .size = mt.size,
                                .x = x + mt.x,
                                .y = baseline + t.y_offset + mt.y,
                                .color = t.color,
                                .scale_x = mt.scale_x,
                                .scale_y = mt.scale_y,
                            } }),
                            .rule => |mr| try page.items.append(.{ .rule = .{
                                .x = x + mr.x,
                                .y = baseline + t.y_offset + mr.y,
                                .w = mr.w,
                                .thickness = mr.thickness,
                                .color = t.color,
                            } }),
                        }
                    }
                    x += b.w;
                },
            }
        }
    }

    fn placeList(self: *Engine, l: ast.List, depth: usize) LayoutError!void {
        const st = self.style;
        const marker_font = fonts.familyFont(st.family, .regular);

        // 悬挂缩进：正文起始位置由最宽的标记决定，跨页时标记与正文仍然对齐
        var widest: f64 = 0;
        for (l.items, 0..) |_, i| {
            widest = @max(widest, fonts.measure(try self.listMarker(l.ordered, i), marker_font, st.size));
        }
        const hang = @max(widest + st.size * 0.5, st.size * 1.2);
        const left_offset = @as(f64, @floatFromInt(depth)) * st.size * 1.6;
        const measure = self.colWidth() - @as(f64, @floatFromInt(depth)) * st.size * 1.6 - hang;

        for (l.items, 0..) |item, i| {
            const m = try self.listMarker(l.ordered, i);
            const tokens = try self.tokensFromInlines(item.content, st.size, st.family, st.text_color);
            const lines = try self.breakTokens(tokens, measure);
            try self.placeLines(lines, left_offset + hang, 0, st.justify, Marker{
                .text = m,
                .font = marker_font,
                .size = st.size,
                .color = st.muted_color,
                .width = hang,
            }, measure);
            self.cursor -= st.size * 0.35;
            if (item.children.len > 0) try self.placeListChildren(item.children, depth + 1);
        }
        self.cursor -= st.parskip * 0.5;
    }

    fn listMarker(self: *Engine, ordered: bool, index: usize) LayoutError![]const u8 {
        if (!ordered) return "\u{2022}";
        return std.fmt.allocPrint(self.allocator, "{d}.", .{index + 1}) catch "";
    }

    fn placeListChildren(self: *Engine, items: []ast.ListItem, depth: usize) LayoutError!void {
        const st = self.style;
        const marker_font = fonts.familyFont(st.family, .regular);
        var widest: f64 = 0;
        for (items, 0..) |_, i| {
            widest = @max(widest, fonts.measure(try self.listMarker(true, i), marker_font, st.size));
        }
        const hang = @max(widest + st.size * 0.5, st.size * 1.2);
        const left_offset = @as(f64, @floatFromInt(depth)) * st.size * 1.6;
        const measure = self.colWidth() - @as(f64, @floatFromInt(depth)) * st.size * 1.6 - hang;

        for (items, 0..) |item, i| {
            const m = try self.listMarker(true, i);
            const tokens = try self.tokensFromInlines(item.content, st.size, st.family, st.text_color);
            const lines = try self.breakTokens(tokens, measure);
            try self.placeLines(lines, left_offset + hang, 0, st.justify, Marker{
                .text = m,
                .font = marker_font,
                .size = st.size,
                .color = st.muted_color,
                .width = hang,
            }, measure);
            self.cursor -= st.size * 0.35;
            if (item.children.len > 0) try self.placeListChildren(item.children, depth + 1);
        }
        self.cursor -= st.parskip * 0.5;
    }

    fn placeQuote(self: *Engine, q: ast.Quote) LayoutError!void {
        const st = self.style;
        const indent = st.size * 1.5;
        if (self.cursor - st.parskip < self.bottom_limit) try self.breakColumn();
        self.cursor -= st.parskip;
        const top = self.cursor;

        var adjusted = st;
        adjusted.margins.left = self.colX(st.margins.left) + indent;
        adjusted.measure = self.colWidth() - indent;
        adjusted.size = st.quote_size;

        const est = try self.estimateBlocks(q.content, adjusted, self.colWidth() - indent);
        if (self.cursor - est < self.bottom_limit + self.footnote_reserve) try self.breakColumn();

        for (q.content) |*b| {
            switch (b.*) {
                .paragraph => |p| {
                    const tokens = try self.tokensFromInlines(p.content, adjusted.size, adjusted.family, st.muted_color);
                    const lines = try self.breakTokens(tokens, adjusted.contentWidth());
                    try self.placeLines(lines, indent, 0, st.justify, null, self.colWidth() - indent);
                },
                else => try self.placeBlock(b.*),
            }
        }

        if (q.source) |src| {
            const tokens = try self.tokensFromInlines(&[_]ast.Inline{.{ .text = src }}, st.caption_size, st.family, st.muted_color);
            const lines = try self.breakTokens(tokens, adjusted.contentWidth());
            try self.placeLines(lines, indent, 0, st.justify, null, self.colWidth() - indent);
        }

        const bottom = self.cursor;
        try self.currentPage().items.append(.{ .rect = .{
            .x = self.colX(st.margins.left),
            .y = bottom,
            .w = 2.0,
            .h = top - bottom,
            .fill = st.accent_color,
        } });
        self.cursor -= st.parskip;
    }

    fn placeCode(self: *Engine, c: ast.CodeBlock) LayoutError!void {
        const st = self.style;
        // 等宽代码不断词
        const prev_hyphen = self.withHyphen(false);
        defer self.allow_hyphen = prev_hyphen;
        // 等宽字体不追加字距
        const prev_tracking = self.withTracking(0);
        defer self.current_tracking = prev_tracking;
        var lines_text = std.array_list.Managed([]const u8).init(self.allocator);
        var iter = std.mem.splitScalar(u8, c.source, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            try lines_text.append(line);
        }
        if (lines_text.items.len == 0) return;

        const font = fonts.familyFont(.mono, .regular);
        const size = st.code_size;
        const line_h = size * 1.45;
        const pad = size * 0.8;
        // 超出版心的代码行按字形宽度折行（代码不断词，也不加字距）
        const max_w = self.colWidth() - 2 * pad;
        var wrapped = std.array_list.Managed([][]const u8).init(self.allocator);
        for (lines_text.items) |line| {
            try wrapped.append(try self.wrapCodeLine(line, font, size, max_w));
        }
        const total_h = @as(f64, @floatFromInt(wrapped.items.len)) * line_h + 2 * pad;

        if (self.cursor - total_h < self.bottom_limit + self.footnote_reserve) try self.breakColumn();

        const top = self.cursor;
        try self.currentPage().items.append(.{ .rect = .{
            .x = self.colX(st.margins.left),
            .y = top - total_h,
            .w = self.colWidth(),
            .h = total_h,
            .fill = .{ .r = 0.95, .g = 0.96, .b = 0.97 },
        } });

        var y = top - pad - size;
        for (wrapped.items) |chunk_group| {
            for (chunk_group) |line| {
                try self.currentPage().items.append(.{ .text = .{
                    .text = line,
                    .font = font,
                    .size = size,
                    .x = self.colX(st.margins.left) + pad,
                    .y = y,
                    .color = st.text_color,
                } });
                y -= line_h;
            }
        }
        self.cursor = top - total_h - st.parskip;
    }

    /// 代码折行：一行放不下时按字形宽度硬折，优先在空白处断开
    fn wrapCodeLine(self: *Engine, line: []const u8, font: fonts.Font, size: f64, max_w: f64) LayoutError![][]const u8 {
        var out = std.array_list.Managed([]const u8).init(self.allocator);
        if (max_w <= 0 or fonts.measure(line, font, size) <= max_w) {
            try out.append(line);
            return out.toOwnedSlice();
        }
        var start: usize = 0;
        var last_space: usize = 0;
        var w: f64 = 0;
        var i: usize = 0;
        while (i < line.len) {
            const len = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            const cp = std.unicode.utf8Decode(line[i .. i + len]) catch line[i];
            const cw = fonts.glyphWidth(cp, font, size);
            if (w + cw > max_w) {
                const cut = if (last_space > start) last_space else i;
                if (cut > start) {
                    try out.append(line[start..cut]);
                    start = cut;
                    w = 0;
                    last_space = 0;
                }
            }
            if (cp == ' ' or cp == '\t') last_space = i + len;
            w += cw;
            i += len;
        }
        if (start < line.len) try out.append(line[start..]);
        if (out.items.len == 0) try out.append(line);
        return out.toOwnedSlice();
    }

    fn placeFigure(self: *Engine, f: ast.Figure) LayoutError!void {
        const st = self.style;
        const width = f.width orelse self.colWidth();
        const height = width * 0.66;

        var caption_lines: []Line = &.{};
        if (f.caption != null) {
            const label = if (f.number) |n| std.fmt.allocPrint(self.allocator, "{s}  {s}", .{ n, f.caption.? }) catch f.caption.? else f.caption.?;
            const tokens = try self.tokensFromInlines(&[_]ast.Inline{.{ .text = label }}, st.caption_size, st.family, st.muted_color);
            caption_lines = try self.breakTokens(tokens, self.colWidth());
        }
        const caption_h = @as(f64, @floatFromInt(caption_lines.len)) * st.caption_size * 1.35;

        // 图与题注不可分离
        if (self.cursor - height - caption_h < self.bottom_limit + self.footnote_reserve) try self.breakColumn();
        const top = self.cursor;
        if (f.src != null) {
            try self.currentPage().items.append(.{ .image = .{
                .src = f.src.?,
                .x = self.colX(st.margins.left),
                .y = top - height,
                .w = width,
                .h = height,
            } });
        } else {
            try self.currentPage().items.append(.{ .rect = .{
                .x = self.colX(st.margins.left),
                .y = top - height,
                .w = width,
                .h = height,
                .stroke = st.muted_color,
            } });
        }
        self.cursor = top - height;
        if (f.caption != null) {
            self.cursor -= st.caption_size * 0.5;
            try self.placeLines(caption_lines, 0, 0, st.justify, null, self.colWidth());
        }
        self.cursor -= st.parskip;
    }

    fn placeTable(self: *Engine, t: ast.Table) LayoutError!void {
        const st = self.style;
        if (t.headers.len == 0 and t.rows.len == 0) return;
        // 表格单元格窄，断词会破坏列宽计算
        const prev_hyphen = self.withHyphen(false);
        defer self.allow_hyphen = prev_hyphen;
        const cols = @max(t.headers.len, if (t.rows.len > 0) t.rows[0].len else 0);
        if (cols == 0) return;

        const pad_v = st.size * 0.45;
        const pad_h = st.size * 0.4;
        const measure = self.colWidth();

        // 每列的自然宽度：首选宽度（整格单行）与最小宽度（不可断行的最长单词）
        var pref = std.array_list.Managed(f64).init(self.allocator);
        var min_w = std.array_list.Managed(f64).init(self.allocator);
        for (0..cols) |c| {
            var wmax: f64 = 0;
            var wmin: f64 = 0;
            if (t.headers.len > c) {
                wmax = @max(wmax, cellWidth(t.headers[c], st.size, st.family, .bold));
                wmin = @max(wmin, cellMinWidth(t.headers[c], st.size, st.family, .bold));
            }
            for (t.rows) |row| {
                if (c >= row.len) continue;
                wmax = @max(wmax, cellWidth(row[c], st.size, st.family, .regular));
                wmin = @max(wmin, cellMinWidth(row[c], st.size, st.family, .regular));
            }
            try pref.append(wmax + 2 * pad_h);
            try min_w.append(@max(wmin + 2 * pad_h, st.size));
        }

        // 显式列宽（对齐行里的 `<2cm`、`^30%`、`>2fr`）优先。未指定的列按自然宽度分配：
        // 存在 fr 列时先满足各列的自然宽度、剩余空间由 fr 列瓜分（Typst 语义）；
        // 否则整块版心按自然宽度比例填满，这样表格不会缩成一小块。
        var col_w = std.array_list.Managed(f64).init(self.allocator);
        var specs = std.array_list.Managed(?ast.ColumnWidth).init(self.allocator);
        var fixed: f64 = 0;
        var auto_total: f64 = 0;
        var fr_total: f64 = 0;
        for (0..cols) |c| {
            const spec = if (c < t.widths.len) t.widths[c] else null;
            try specs.append(spec);
            if (spec) |s| switch (s) {
                .length => fixed += s.length,
                .fraction => fixed += s.fraction * measure,
                .fr => fr_total += s.fr,
                .auto => auto_total += pref.items[c],
            } else auto_total += pref.items[c];
        }

        const leftover = measure - fixed;
        for (0..cols) |c| {
            const spec = specs.items[c];
            const natural = pref.items[c];
            const w: f64 = if (spec) |s| switch (s) {
                .length => s.length,
                .fraction => s.fraction * measure,
                .fr => if (fr_total > 0 and leftover > auto_total) (leftover - auto_total) * s.fr / fr_total else min_w.items[c],
                .auto => if (fr_total > 0) natural else leftover * natural / @max(auto_total, 1e-6),
            } else if (fr_total > 0) natural else leftover * natural / @max(auto_total, 1e-6);
            try col_w.append(@max(w, min_w.items[c]));
        }

        var total: f64 = 0;
        for (col_w.items) |w| total += w;
        // 最小宽度钳制后可能超出版心：按比例压缩，保证不溢出
        if (total > measure) {
            const scale = measure / total;
            for (col_w.items) |*w| w.* *= scale;
            total = measure;
        }

        // 每个单元格的行数
        var row_lines = std.array_list.Managed([][]Line).init(self.allocator);
        const has_header = t.headers.len > 0;
        const all_rows = @as(usize, @intFromBool(has_header)) + t.rows.len;
        for (0..all_rows) |r| {
            const cells = if (has_header and r == 0) t.headers else t.rows[if (has_header) r - 1 else r];
            var lines = std.array_list.Managed([]Line).init(self.allocator);
            for (0..cols) |c| {
                if (c >= cells.len) {
                    try lines.append(&.{});
                    continue;
                }
                const header_variant: fonts.Variant = if (has_header and r == 0) .bold else .regular;
                const tokens = try self.tokensFromInlinesWithVariant(cells[c], st.size, st.family, st.text_color, header_variant);
                try lines.append(try self.breakTokens(tokens, col_w.items[c] - 2 * pad_h));
            }
            try row_lines.append(try lines.toOwnedSlice());
        }

        // 题注在表格上方（booktabs / 现代排版），并与表头留在同一页
        if (t.caption != null) {
            const label = if (t.number) |n| std.fmt.allocPrint(self.allocator, "{s}  {s}", .{ n, t.caption.? }) catch t.caption.? else t.caption.?;
            const tokens = try self.tokensFromInlines(&[_]ast.Inline{.{ .text = label }}, st.caption_size, st.family, st.text_color);
            const lines = try self.breakTokens(tokens, self.colWidth());
            const first_row_h = blockHeight(row_lines.items[0], col_w.items, pad_v, st);
            const needed = @as(f64, @floatFromInt(lines.len)) * st.caption_size * 1.35 + first_row_h + st.caption_size * 0.5;
            if (self.cursor - needed < self.bottom_limit + self.footnote_reserve) try self.breakColumn();
            try self.placeLines(lines, 0, 0, st.justify, null, self.colWidth());
            self.cursor -= st.caption_size * 0.5;
        }

        const header_h = if (has_header) blockHeight(row_lines.items[0], col_w.items, pad_v, st) else 0;

        // booktabs：只有三条横线，行与行之间不画框线
        const top = self.cursor;
        if (has_header) {
            if (self.cursor - header_h < self.bottom_limit + self.footnote_reserve) try self.breakColumn();
            try self.drawTableHeader(row_lines.items[0], col_w.items, self.cursor, pad_v, pad_h, st, t.alignments, total);
        } else {
            try self.currentPage().items.append(.{ .rule = .{
                .x = self.colX(st.margins.left),
                .y = top,
                .w = total,
                .thickness = 0.8,
                .color = st.text_color,
            } });
        }

        for (1..all_rows) |r| {
            const h = blockHeight(row_lines.items[r], col_w.items, pad_v, st);
            if (self.cursor - h < self.bottom_limit + self.footnote_reserve) {
                try self.breakColumn();
                // 跨页时重绘表头
                if (has_header) try self.drawTableHeader(row_lines.items[0], col_w.items, self.cursor, pad_v, pad_h, st, t.alignments, total);
            }
            try self.drawRow(row_lines.items[r], col_w.items, self.cursor, pad_v, pad_h, st, t.alignments);
        }
        try self.currentPage().items.append(.{ .rule = .{
            .x = self.colX(st.margins.left),
            .y = self.cursor,
            .w = total,
            .thickness = 0.8,
            .color = st.text_color,
        } });
        self.cursor -= st.parskip;
    }

    fn drawTableHeader(self: *Engine, lines: [][]Line, col_w: []f64, top: f64, pad_v: f64, pad_h: f64, st: style.Style, aligns: []ast.Alignment, total: f64) LayoutError!void {
        const page = self.currentPage();
        try page.items.append(.{ .rule = .{
            .x = self.colX(st.margins.left),
            .y = top,
            .w = total,
            .thickness = 0.8,
            .color = st.text_color,
        } });
        try self.drawRow(lines, col_w, top, pad_v, pad_h, st, aligns);
        try self.currentPage().items.append(.{ .rule = .{
            .x = self.colX(st.margins.left),
            .y = self.cursor,
            .w = total,
            .thickness = 0.5,
            .color = st.muted_color,
        } });
    }

    fn drawRow(self: *Engine, lines: [][]Line, col_w: []f64, top: f64, pad_v: f64, pad_h: f64, st: style.Style, aligns: []ast.Alignment) LayoutError!void {
        var row_h: f64 = 0;
        for (lines) |cell| {
            var h: f64 = 0;
            for (cell) |line| h = @max(h, line.height + line.depth);
            row_h = @max(row_h, h);
        }
        row_h += 2 * pad_v;

        var x = self.colX(st.margins.left);
        for (lines, 0..) |cell, c| {
            const cell_w = col_w[c] - 2 * pad_h;
            var offset: f64 = pad_h;
            if (c < aligns.len and cell_w > 0) {
                var widest: f64 = 0;
                for (cell) |line| widest = @max(widest, line.natural);
                switch (aligns[c]) {
                    .left => offset = pad_h,
                    .center => offset = pad_h + (cell_w - widest) / 2.0,
                    .right => offset = pad_h + cell_w - widest,
                }
                if (offset < pad_h) offset = pad_h;
            }

            var y = top - pad_v;
            for (cell) |line| {
                const needed = @max(st.size * 1.3, line.height + line.depth);
                const baseline = y - line.height;
                try self.emitLine(line, x + offset, baseline, false, cell_w);
                y -= needed;
            }
            x += col_w[c];
        }
        self.cursor = top - row_h;
    }

    fn blockHeight(lines: [][]Line, col_w: []f64, pad_v: f64, st: style.Style) f64 {
        _ = col_w;
        _ = st;
        var h: f64 = 0;
        for (lines) |cell| {
            var ch: f64 = 0;
            for (cell) |line| ch = @max(ch, line.height + line.depth);
            h = @max(h, ch);
        }
        return h + 2 * pad_v;
    }

    fn placeCallout(self: *Engine, c: ast.Callout) LayoutError!void {
        const st = self.style;
        const pad = st.size * 0.8;
        const measure = self.colWidth() - 2 * pad;

        // 先估算内容高度
        const est = try self.estimateBlocks(c.content, st, measure);
        if (self.cursor - (est + 2 * pad) < self.bottom_limit + self.footnote_reserve) try self.breakColumn();

        const page_number = self.currentPage().number;
        const content_top = self.cursor - pad;
        const rect_index = self.currentPage().items.items.len;
        try self.currentPage().items.append(.{ .rect = .{
            .x = self.colX(st.margins.left),
            .y = content_top - est,
            .w = self.colWidth(),
            .h = est + 2 * pad,
            .fill = calloutColor(c.kind),
        } });

        if (c.title != null) {
            const tokens = try self.tokensFromInlines(&[_]ast.Inline{.{ .text = c.title.? }}, st.size, st.family, calloutAccent(c.kind));
            const lines = try self.breakTokens(tokens, measure);
            try self.placeLines(lines, pad, 0, st.justify, null, measure);
        }
        for (c.content) |b| {
            switch (b) {
                .paragraph => |p| {
                    const tokens = try self.tokensFromInlines(p.content, st.size, st.family, st.text_color);
                    const lines = try self.breakTokens(tokens, measure);
                    try self.placeLines(lines, pad, 0, st.justify, null, measure);
                },
                else => try self.placeBlock(b),
            }
        }
        self.cursor -= pad;
        // 估算与实际内容高度不一致时修正背景框（跨页时保留已绘制的那一页）
        if (self.currentPage().number == page_number) {
            const page = self.currentPage();
            page.items.items[rect_index].rect.h = content_top - self.cursor + pad;
            page.items.items[rect_index].rect.y = self.cursor;
        }
    }

    fn estimateBlocks(self: *Engine, blocks: []ast.Block, st: style.Style, measure: f64) LayoutError!f64 {
        var total: f64 = 0;
        for (blocks) |b| {
            switch (b) {
                .paragraph => |p| {
                    const tokens = try self.tokensFromInlines(p.content, st.size, st.family, st.text_color);
                    const lines = try self.breakTokens(tokens, measure);
                    for (lines) |line| total += @max(st.leading, line.height + line.depth);
                    total += st.parskip;
                },
                .heading => |*h| {
                    const tokens = try self.tokensFromInlines(h.text, st.heading_sizes[h.level - 1], st.heading_family, st.text_color);
                    const lines = try self.breakTokens(tokens, measure);
                    for (lines) |line| total += @max(st.heading_sizes[h.level - 1] * 1.25, line.height + line.depth);
                },
                else => total += st.leading,
            }
        }
        return total;
    }

    fn placeMathBlock(self: *Engine, m: ast.MathBlock) LayoutError!void {
        const st = self.style;
        self.math_layout.display = true;

        // Typst：tag(...) 从公式主体中分离出来，贴到版心右边缘，主体在剩余宽度内居中
        const tag = mathTag(m.nodes);
        var body = std.array_list.Managed(math.Node).init(self.allocator);
        for (m.nodes) |node| {
            if (node == .tag) continue;
            try body.append(node);
        }
        const box = self.math_layout.layout(.{ .row = body.items }, st.math_size);

        const left = self.colX(st.margins.left);
        const measure = self.colWidth();
        var tag_box: ?mathlayout.Box = null;
        if (tag) |t| {
            if (!t.suppress) tag_box = self.math_layout.layout(t.body.*, st.math_size);
        }
        const tag_gap = st.size;
        const avail = if (tag_box != null) measure - tag_box.?.w - tag_gap else measure;

        // 超出版心：在顶层关系符处断行（Typst 的 align 行为），各行共用同一个对齐点
        if (box.w > avail) {
            const parts = try self.mathBreakParts(body.items, st.math_size);
            if (parts.len > 1) {
                try self.placeMathParts(parts, left, avail, tag_box, m.number);
                return;
            }
        }

        const line_h = @max(st.leading, box.h + box.d);
        if (self.cursor - line_h < self.bottom_limit + self.footnote_reserve) try self.breakColumn();
        const top = self.cursor;
        const baseline = top - @max(0, (line_h - (box.h + box.d)) / 2.0) - box.h;
        const x = left + (avail - box.w) / 2.0;

        const page = self.currentPage();
        try self.drawMathBox(page, box, x, baseline, st.text_color);
        if (tag_box) |tb| {
            const tx = left + measure - tb.w;
            try self.drawMathBox(page, tb, tx, baseline, st.muted_color);
        } else if (m.number) |num| {
            const font = fonts.familyFont(st.family, .regular);
            const w = fonts.measure(num, font, st.size);
            try page.items.append(.{ .text = .{
                .text = num,
                .font = font,
                .size = st.size,
                .x = left + measure - w,
                .y = baseline,
                .color = st.muted_color,
            } });
        }
        self.cursor -= line_h + st.parskip * 0.5;
    }

    fn drawMathBox(_: *Engine, page: *Page, box: mathlayout.Box, x: f64, baseline: f64, color: Color) LayoutError!void {
        for (box.items) |mi| {
            switch (mi) {
                .text => |mt| try page.items.append(.{ .text = .{
                    .text = mt.text,
                    .font = mt.font,
                    .size = mt.size,
                    .x = x + mt.x,
                    .y = baseline + mt.y,
                    .color = color,
                    .scale_x = mt.scale_x,
                    .scale_y = mt.scale_y,
                } }),
                .rule => |mr| try page.items.append(.{ .rule = .{
                    .x = x + mr.x,
                    .y = baseline + mr.y,
                    .w = mr.w,
                    .thickness = mr.thickness,
                    .color = color,
                } }),
            }
        }
    }

    /// 按顶层关系符把公式切成段：首段可能是前缀，其余各段以关系符开头
    fn mathBreakParts(self: *Engine, nodes: []math.Node, size: f64) LayoutError![]MathPart {
        var rels = std.array_list.Managed(usize).init(self.allocator);
        for (nodes, 0..) |node, i| {
            if (math.texClass(node) == .rel) try rels.append(i);
        }

        var parts = std.array_list.Managed(MathPart).init(self.allocator);
        if (rels.items.len == 0) {
            try parts.append(self.mathPart(nodes, false, size));
            return try parts.toOwnedSlice();
        }
        if (rels.items[0] > 0) try parts.append(self.mathPart(nodes[0 .. rels.items[0]], false, size));
        for (rels.items, 0..) |r, i| {
            const end = if (i + 1 < rels.items.len) rels.items[i + 1] else nodes.len;
            try parts.append(self.mathPart(nodes[r..end], true, size));
        }
        return try parts.toOwnedSlice();
    }

    fn mathPart(self: *Engine, nodes: []math.Node, aligned: bool, size: f64) MathPart {
        return MathPart{
            .nodes = nodes,
            .box = self.math_layout.layout(.{ .row = nodes }, size),
            .first_class = math.texClass(nodes[0]),
            .last_class = math.texClass(nodes[nodes.len - 1]),
            .aligned = aligned,
        };
    }

    /// 段分组成行（不超过可用宽度），在同一对齐点排布；行距沿用 TeX 模型
    fn placeMathParts(self: *Engine, parts: []MathPart, left: f64, avail: f64, tag_box: ?mathlayout.Box, number: ?[]const u8) LayoutError!void {
        const st = self.style;

        var lines = std.array_list.Managed([]MathPart).init(self.allocator);
        var current = std.array_list.Managed(MathPart).init(self.allocator);
        var used: f64 = 0;
        for (parts) |part| {
            if (current.items.len > 0) {
                const gap = self.math_layout.spacing(current.items[current.items.len - 1].last_class, part.first_class, st.math_size);
                if (used + gap + part.box.w > avail) {
                    try lines.append(try current.toOwnedSlice());
                    used = 0;
                } else {
                    used += gap;
                }
            }
            try current.append(part);
            used += part.box.w;
        }
        if (current.items.len > 0) try lines.append(try current.toOwnedSlice());

        const MathLine = struct {
            parts: []MathPart,
            h: f64,
            d: f64,
            /// 对齐点左侧的伸出量（首段是前缀时不为零）
            left_extent: f64,
        };
        var rows = std.array_list.Managed(MathLine).init(self.allocator);
        var max_left: f64 = 0;
        var max_right: f64 = 0;
        for (lines.items) |line| {
            var h: f64 = 0;
            var d: f64 = 0;
            var width: f64 = 0;
            for (line, 0..) |part, i| {
                if (i > 0) width += self.math_layout.spacing(line[i - 1].last_class, part.first_class, st.math_size);
                width += part.box.w;
                h = @max(h, part.box.h);
                d = @max(d, part.box.d);
            }
            var left_extent: f64 = 0;
            if (!line[0].aligned) {
                left_extent = line[0].box.w;
                if (line.len > 1) left_extent += self.math_layout.spacing(line[0].last_class, line[1].first_class, st.math_size);
            }
            try rows.append(MathLine{ .parts = line, .h = h, .d = d, .left_extent = left_extent });
            max_left = @max(max_left, left_extent);
            max_right = @max(max_right, width - left_extent);
        }

        var align_x = left + (avail - (max_left + max_right)) / 2.0 + max_left;
        if (align_x < left) align_x = left;

        var prev_baseline: ?f64 = null;
        var prev_depth: f64 = 0;
        for (rows.items) |row| {
            const span = @max(st.leading, row.h + prev_depth + st.lineskip);
            if (self.cursor - span < self.bottom_limit + self.footnote_reserve) {
                try self.breakColumn();
                prev_baseline = null;
                prev_depth = 0;
            }
            const baseline = if (prev_baseline == null)
                self.cursor - @max(0.0, (st.leading - (row.h + row.d)) / 2.0) - row.h
            else
                prev_baseline.? - span;

            const page = self.currentPage();
            var x = align_x - row.left_extent;
            for (row.parts, 0..) |part, i| {
                if (i > 0) x += self.math_layout.spacing(row.parts[i - 1].last_class, part.first_class, st.math_size);
                try self.drawMathBox(page, part.box, x, baseline, st.text_color);
                x += part.box.w;
            }
            prev_baseline = baseline;
            prev_depth = row.d;
            self.cursor -= span;
        }

        // 编号或 tag 贴在最后一行的基线上
        const last_baseline = prev_baseline orelse self.cursor;
        const page = self.currentPage();
        if (tag_box) |tb| {
            try self.drawMathBox(page, tb, left + avail, last_baseline, st.muted_color);
        } else if (number) |num| {
            const font = fonts.familyFont(st.family, .regular);
            const w = fonts.measure(num, font, st.size);
            try page.items.append(.{ .text = .{
                .text = num,
                .font = font,
                .size = st.size,
                .x = left + avail - w,
                .y = last_baseline,
                .color = st.muted_color,
            } });
        }
        self.cursor -= st.parskip * 0.5;
    }

    fn placeBibliography(self: *Engine, b: ast.Bibliography) LayoutError!void {
        const st = self.style;
        if (b.entries.len == 0) return;
        const font = fonts.familyFont(st.family, .regular);

        const title = b.title orelse st.bibliography_label();
        const title_font = fonts.familyFont(st.heading_family, .bold);
        const title_size = st.heading_sizes[1];
        if (self.cursor - title_size * 1.2 < self.bottom_limit + self.footnote_reserve) try self.breakColumn();
        self.cursor -= st.heading_before[1];
        try self.currentPage().items.append(.{ .text = .{
            .text = title,
            .font = title_font,
            .size = title_size,
            .x = self.colX(st.margins.left),
            .y = self.cursor - fonts.ascent(title_font, title_size),
            .color = st.text_color,
        } });
        try self.currentPage().bookmarks.append(.{ .level = 2, .title = title, .page = self.currentPage().number });
        self.cursor -= title_size * 1.2 + st.heading_after[1];

        // 悬挂缩进的参考文献表：编号在左边距内，正文对齐到同一列
        const hang = st.size * 2.2;
        for (b.entries) |entry| {
            const r = self.refs.get(entry.key);
            const number = if (r != null and r.?.number.len > 0) r.?.number else "?";
            const marker = std.fmt.allocPrint(self.allocator, "[{s}]", .{number}) catch "[?]";
            if (entry.id) |id| {
                try self.refs.put(entry.key, .{ .number = number, .page = self.currentPage().number, .key = id });
            }
            const tokens = try self.tokensFromInlines(entry.text, st.size, st.family, st.text_color);
            const measure = self.colWidth() - hang;
            const lines = try self.breakTokens(tokens, measure);
            try self.placeLines(lines, hang, 0, st.justify, Marker{
                .text = marker,
                .font = font,
                .size = st.size,
                .color = st.muted_color,
                .width = hang,
            }, measure);
            self.cursor -= st.size * 0.45;
        }
        self.cursor -= st.parskip;
    }

    fn placeDefinitionList(self: *Engine, d: ast.DefinitionList) LayoutError!void {
        const st = self.style;
        for (d.entries) |entry| {
            const term_tokens = try self.tokensFromInlines(entry.term, st.size, st.family, st.text_color);
            const term_lines = try self.breakTokens(term_tokens, self.colWidth());
            try self.placeLines(term_lines, 0, 0, false, null, self.colWidth());
            const def_tokens = try self.tokensFromInlines(entry.definition, st.size, st.family, st.muted_color);
            const def_lines = try self.breakTokens(def_tokens, self.colWidth() - st.size * 1.5);
            try self.placeLines(def_lines, st.size * 1.5, 0, false, null, self.colWidth() - st.size * 1.5);
            self.cursor -= st.size * 0.4;
        }
        self.cursor -= st.parskip;
    }

    fn placeRule(self: *Engine) LayoutError!void {
        const st = self.style;
        if (self.cursor - st.parskip < self.bottom_limit) try self.breakColumn();
        self.cursor -= st.parskip * 0.5;
        try self.currentPage().items.append(.{ .rule = .{
            .x = self.colX(st.margins.left),
            .y = self.cursor,
            .w = self.colWidth(),
            .thickness = 0.5,
            .color = st.muted_color,
        } });
        self.cursor -= st.parskip * 0.5;
    }

    fn placeToc(self: *Engine) LayoutError!void {
        const st = self.style;
        if (self.toc.items.len == 0) return;
        const font = fonts.familyFont(st.family, .regular);

        const title = st.toc_title();
        const title_font = fonts.familyFont(st.heading_family, .bold);
        const title_size = st.heading_sizes[0];
        if (self.cursor - st.heading_sizes[0] * 1.2 < self.bottom_limit + self.footnote_reserve) try self.breakColumn();
        try self.currentPage().items.append(.{ .text = .{
            .text = title,
            .font = title_font,
            .size = title_size,
            .x = self.colX(st.margins.left),
            .y = self.cursor - fonts.ascent(title_font, title_size),
            .color = st.text_color,
        } });
        self.cursor -= title_size * 1.2 + st.parskip * 0.5;

        for (self.toc.items) |entry| {
            const indent = @as(f64, @floatFromInt(entry.level - 1)) * st.size * 1.2;
            const page_number = self.heading_pages.get(entry.key) orelse entry.page;
            const page_str = std.fmt.allocPrint(self.allocator, "{d}", .{page_number}) catch "";
            const label = if (entry.number) |n| std.fmt.allocPrint(self.allocator, "{s}  {s}", .{ n, entry.text }) catch entry.text else entry.text;
            const title_w = fonts.measure(label, font, st.size);
            const page_w = fonts.measure(page_str, font, st.size);
            const leader_unit = fonts.glyphWidth('.', font, st.size) + st.size * 0.12;
            const avail = self.colWidth() - indent - title_w - page_w - st.size * 0.6;
            const leader_count: usize = if (avail > leader_unit) @intFromFloat(avail / leader_unit) else 0;

            const needed = @max(st.leading, fonts.ascent(font, st.size) + fonts.descent(font, st.size));
            if (self.cursor - needed < self.bottom_limit + self.footnote_reserve) try self.breakColumn();
            const baseline = self.cursor - fonts.ascent(font, st.size);
            const page = self.currentPage();
            const x0 = self.colX(st.margins.left) + indent;

            try page.items.append(.{ .text = .{
                .text = label,
                .font = font,
                .size = st.size,
                .x = x0,
                .y = baseline,
                .color = st.text_color,
                .link = entry.key,
            } });
            if (leader_count > 0) {
                const leader_text = try self.leaderString(leader_count);
                try page.items.append(.{ .text = .{
                    .text = leader_text,
                    .font = font,
                    .size = st.size,
                    .x = x0 + title_w + st.size * 0.3,
                    .y = baseline,
                    .color = st.muted_color,
                } });
            }
            try page.items.append(.{ .text = .{
                .text = page_str,
                .font = font,
                .size = st.size,
                .x = self.colX(st.margins.left) + self.colWidth() - page_w,
                .y = baseline,
                .color = st.muted_color,
                .link = entry.key,
            } });
            self.cursor -= needed;
        }
        self.cursor -= st.parskip;
    }

    fn leaderString(self: *Engine, count: usize) LayoutError![]const u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        for (0..count) |i| {
            if (i > 0) try out.append(' ');
            try out.append('.');
        }
        return out.toOwnedSlice();
    }

    // ---- 行构建 ----

    pub fn tokensFromInlines(self: *Engine, inlines: []const ast.Inline, size: f64, family: fonts.Family, color: Color) LayoutError![]Token {
        return self.tokensFromInlinesWithVariant(inlines, size, family, color, .regular);
    }

    pub fn tokensFromInlinesWithVariant(self: *Engine, inlines: []const ast.Inline, size: f64, family: fonts.Family, color: Color, variant: fonts.Variant) LayoutError![]Token {
        var out = std.array_list.Managed(Token).init(self.allocator);
        try self.pushInlines(&out, inlines, size, family, variant, color, null);
        return out.toOwnedSlice();
    }

    const Variant = fonts.Variant;

    fn pushInlines(self: *Engine, out: *std.array_list.Managed(Token), inlines: []const ast.Inline, size: f64, family: fonts.Family, variant: Variant, color: Color, link: ?[]const u8) LayoutError!void {
        for (inlines) |node| {
            switch (node) {
                .text => |s| try self.pushText(out, s, size, family, variant, color, link, false),
                .code => |s| try self.pushText(out, s, size * 0.9, .mono, .regular, color, link, false),
                .strong => |kids| try self.pushInlines(out, kids, size, family, .bold, color, link),
                .em => |kids| try self.pushInlines(out, kids, size, family, .italic, color, link),
                .link => |l| try self.pushInlines(out, l.text, size, family, variant, self.style.accent_color, l.url),
                .expr => |s| {
                    var value: []const u8 = s;
                    if (self.resolver) |r| {
                        if (r.evalExpr(s) catch null) |v| value = v;
                    }
                    try self.pushText(out, value, size, family, variant, color, link, false);
                },
                .ref => |id| {
                    const r = self.refs.get(id) orelse Ref{ .number = "", .page = 0, .key = id };
                    const label = if (r.number.len > 0) r.number else id;
                    try self.pushText(out, label, size, family, variant, self.style.accent_color, id, true);
                },
                .cite => |key| {
                    const r = self.refs.get(key);
                    const label = if (r != null and r.?.number.len > 0)
                        (std.fmt.allocPrint(self.allocator, "[{s}]", .{r.?.number}) catch "[?]")
                    else
                        "[?]";
                    try self.pushText(out, label, size, family, variant, self.style.accent_color, key, false);
                },
                .footnote => |kids| {
                    const idx = self.footnote_cursor;
                    self.footnote_cursor += 1;
                    if (idx >= self.footnotes.items.len) return LayoutError.OutOfMemory;
                    // 脚注引用标记
                    const label = self.footnotes.items[idx].label;
                    const font = fonts.familyFont(family, variant);
                    try out.append(Token{
                        .kind = .run,
                        .text = label,
                        .font = font,
                        .size = size * 0.7,
                        .color = self.style.accent_color,
                        .y_offset = size * 0.45,
                        .width = fonts.measure(label, font, size * 0.7),
                        .h = fonts.ascent(font, size * 0.7),
                        .d = fonts.descent(font, size * 0.7),
                        .footnote = idx,
                    });
                    // 正文只保留标记，脚注内容排在栏底（与 HTML 后端一致）
                    _ = kids;
                },
                .math => |nodes| {
                    self.math_layout.display = false;
                    const box = self.math_layout.layout(.{ .row = nodes }, size);
                    try out.append(Token{
                        .kind = .box,
                        .box = box,
                        .width = box.w,
                        .h = box.h,
                        .d = box.d,
                        .color = color,
                        .breakable = false,
                    });
                },
                .sup => |kids| {
                    try self.pushInlinesShifted(out, kids, size * 0.7, family, variant, color, link, size * 0.45);
                },
                .sub => |kids| {
                    try self.pushInlinesShifted(out, kids, size * 0.7, family, variant, color, link, -size * 0.25);
                },
            }
        }
    }

    fn pushInlinesShifted(self: *Engine, out: *std.array_list.Managed(Token), inlines: []const ast.Inline, size: f64, family: fonts.Family, variant: Variant, color: Color, link: ?[]const u8, offset: f64) LayoutError!void {
        const start = out.items.len;
        try self.pushInlines(out, inlines, size, family, variant, color, link);
        for (out.items[start..], 0..) |*t, i| {
            _ = i;
            t.y_offset += offset;
        }
    }

    fn pushText(self: *Engine, out: *std.array_list.Managed(Token), text: []const u8, size: f64, family: fonts.Family, variant: Variant, color: Color, link: ?[]const u8, underline: bool) LayoutError!void {
        const font = fonts.familyFont(family, variant);
        var view = std.unicode.Utf8View.init(text) catch {
            try out.append(Token{
                .kind = .run,
                .text = text,
                .font = font,
                .size = size,
                .color = color,
                .link = link,
                .underline = underline,
                .width = fonts.measure(text, font, size),
                .h = fonts.ascent(font, size),
                .d = fonts.descent(font, size),
                .breakable = true,
            });
            return;
        };

        var iter = view.iterator();
        var start: usize = 0;
        var prev_cjk: ?bool = null;

        while (true) {
            const cp_start = iter.i;
            const cp = iter.nextCodepoint() orelse break;
            if (cp == ' ' or cp == '\t' or cp == '\n') {
                // 词本身不含空白：空白单独成为可伸缩的 glue token
                var sentence_end = false;
                if (start < cp_start) {
                    const word = text[start..cp_start];
                    if (self.style.spacefactor) {
                        if (lastCodepoint(word)) |last| sentence_end = typography.isSentenceEnding(last);
                    }
                    try self.flushWord(out, word, font, size, color, link, underline);
                }
                start = iter.i;
                const base_glue = fonts.glyphWidth(' ', font, size);
                try out.append(Token{
                    .kind = .glue,
                    // TeX 的 spacefactor：句末标点后空格更宽、可伸缩度更高
                    .glue = if (sentence_end) base_glue * 1.25 else base_glue,
                    .font = font,
                    .size = size,
                    .adjustability = if (sentence_end) 2.0 else 1.0,
                });
                prev_cjk = null;
                continue;
            }
            const cjk = fonts.isCjk(cp);
            if (cjk) {
                if (start < cp_start) try self.flushWord(out, text[start..cp_start], font, size, color, link, underline);
                start = iter.i;
                if (prev_cjk == false) {
                    try out.append(Token{ .kind = .glue, .glue = size * 0.1, .font = font, .size = size, .adjustability = 1.0 });
                } else if (prev_cjk == true) {
                    // CJK 字间没有空格，但两端对齐需要可伸缩的间隙（Typst 行为）：
                    // 自然宽度为 0，因此不会成为断点，只参与拉伸分配
                    try out.append(Token{ .kind = .glue, .glue = 0, .font = font, .size = size, .adjustability = 1.0 });
                }
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch continue;
                try out.append(Token{
                    .kind = .run,
                    .text = try self.allocator.dupe(u8, buf[0..n]),
                    .font = if (cjk) .cjk else font,
                    .size = size,
                    .color = color,
                    .link = link,
                    .underline = underline,
                    .width = fonts.glyphWidth(cp, if (cjk) .cjk else font, size) + self.current_tracking,
                    .tracking = self.current_tracking,
                    .h = fonts.ascent(if (cjk) .cjk else font, size),
                    .d = fonts.descent(if (cjk) .cjk else font, size),
                    .breakable = true,
                    .hanging = isHangingPunctuation(cp),
                    .no_break_before = isCjkNoBreakBefore(cp),
                    .no_break_after = isCjkNoBreakAfter(cp),
                });
                prev_cjk = true;
                continue;
            }
            if (prev_cjk == true) {
                if (start < cp_start) {
                    try out.append(Token{ .kind = .glue, .glue = size * 0.1, .font = font, .size = size, .adjustability = 1.0 });
                    start = iter.i;
                }
            }
            prev_cjk = false;
        }
        if (start < text.len) try self.flushWord(out, text[start..], font, size, color, link, underline);
    }

    fn lastCodepoint(text: []const u8) ?u21 {
        var last: ?u21 = null;
        var view = std.unicode.Utf8View.init(text) catch return null;
        var iter = view.iterator();
        while (iter.nextCodepoint()) |cp| last = cp;
        return last;
    }

    fn flushWord(self: *Engine, out: *std.array_list.Managed(Token), word: []const u8, font: fonts.Font, size: f64, color: Color, link: ?[]const u8, underline: bool) LayoutError!void {
        if (word.len == 0) return;

        const all_punct = isAllPunctuation(word);
        if (!self.style.hyphen or !self.allow_hyphen or all_punct) {
            try appendRun(out, word, font, size, color, link, underline, all_punct, 0, true, self.current_tracking);
            return;
        }

        // TeX：连字符复合词的每一部分独立断词，已有连字符本身就是断点（exhyphenpenalty）
        if (std.mem.indexOfScalar(u8, word, '-') != null) {
            var rest = word;
            while (rest.len > 0) {
                const cut = std.mem.indexOfScalar(u8, rest, '-');
                const part = if (cut == null) rest else rest[0 .. cut.?];
                try self.hyphenateRun(out, part, font, size, color, link, underline);
                if (cut == null) break;
                try appendRun(out, "-", font, size, color, link, underline, false, exhyphen_penalty, true, self.current_tracking);
                rest = rest[cut.? + 1 ..];
            }
            return;
        }

        try self.hyphenateRun(out, word, font, size, color, link, underline);
    }

    /// 把单个（不含连字符的）单词拆成音节，音节之间插入 discretionary hyphen
    fn hyphenateRun(self: *Engine, out: *std.array_list.Managed(Token), word: []const u8, font: fonts.Font, size: f64, color: Color, link: ?[]const u8, underline: bool) LayoutError!void {
        if (word.len == 0) return;
        const core = alphabeticCore(word);
        if (core.len < hyphenate.min_word) {
            try appendRun(out, word, font, size, color, link, underline, false, 0, true, self.current_tracking);
            return;
        }
        const pts = hyphenate.points(&self.hyphen_table, core, .{}) catch &.{};
        if (pts.len == 0) {
            try appendRun(out, word, font, size, color, link, underline, false, 0, true, self.current_tracking);
            return;
        }

        // core 可能是 word 的子串（首字母大写、带标点），断点位置要换算回 word 的偏移
        const core_start = std.mem.indexOfScalar(u8, word, core[0]) orelse 0;
        const hy_w = fonts.glyphWidth('-', font, size);
        var start: usize = 0;
        for (pts) |p| {
            const pos = core_start + p;
            try appendRun(out, word[start..pos], font, size, color, link, underline, false, 0, false, self.current_tracking);
            try out.append(Token{
                .kind = .discretionary,
                .text = "-",
                .font = font,
                .size = size,
                .color = color,
                .link = link,
                .underline = underline,
                .width = hy_w + self.current_tracking,
                .tracking = self.current_tracking,
                .h = fonts.ascent(font, size),
                .d = fonts.descent(font, size),
                .penalty = hyphen_penalty,
                .adjustability = 2.0,
                .discretionary = true,
            });
            start = pos;
        }
        try appendRun(out, word[start..], font, size, color, link, underline, false, 0, true, self.current_tracking);
    }

    // ---- 最优断行（Knuth-Plass）----
    // 每条候选行计算 demerit = (1 + 可伸缩度) * delta^2 + 惩罚，
    // 用动态规划在全部断点中选择总 demerit 最小的一组断行。

    pub fn breakTokens(self: *Engine, tokens: []const Token, measure: f64) LayoutError![]Line {
        var lines = std.array_list.Managed(Line).init(self.allocator);
        const n = tokens.len;
        if (n == 0) return lines.toOwnedSlice();
        const eff_measure = if (measure > 0) measure else 1.0;

        var can_break = try self.allocator.alloc(bool, n);
        var break_penalty = try self.allocator.alloc(i32, n);
        for (tokens, 0..) |t, i| {
            switch (t.kind) {
                .glue => {
                    can_break[i] = t.glue > 0;
                    break_penalty[i] = t.penalty;
                },
                .discretionary => {
                    can_break[i] = true;
                    break_penalty[i] = t.penalty;
                },
                .run, .box => {
                    can_break[i] = t.breakable and !t.no_break_after;
                    break_penalty[i] = t.penalty;
                },
            }
        }

        // CJK 行首禁则：闭标点不能出现在行首，因此它前面的断点全部取消
        for (0..n) |i| {
            if (can_break[i] and i + 1 < n and tokens[i + 1].no_break_before) can_break[i] = false;
        }

        const inf = std.math.inf(f64);
        const best = try self.allocator.alloc(f64, n);
        const prev = try self.allocator.alloc(usize, n);
        const was_hyphen = try self.allocator.alloc(bool, n);
        const line_hang_left = try self.allocator.alloc(f64, n);
        const line_hang_right = try self.allocator.alloc(f64, n);
        for (0..n) |i| {
            best[i] = inf;
            prev[i] = n;
            was_hyphen[i] = false;
            line_hang_left[i] = 0;
            line_hang_right[i] = 0;
        }

        for (0..n) |start| {
            if (start > 0 and best[start - 1] == inf) continue;
            const base = if (start == 0) 0.0 else best[start - 1];
            const prev_hyphen = if (start == 0) false else was_hyphen[start - 1];

            var natural: f64 = 0;
            var adj: f64 = 0;
            var natural_trim: f64 = 0;
            var hang_left: f64 = 0;
            var hang_right: f64 = 0;
            var content_count: usize = 0;
            var first = true;

            for (start..n) |j| {
                const t = tokens[j];
                // 行首的 glue 属于上一行的行末 glue，排版时会被丢弃
                if (first and t.kind == .glue) continue;
                if (t.kind == .discretionary) {
                    if (!can_break[j]) continue;
                    const w = natural + t.width;
                    const d = lineDemerit(w, eff_measure, adj + 2.0, break_penalty[j], prev_hyphen, j == n - 1);
                    if (base + d < best[j]) {
                        best[j] = base + d;
                        prev[j] = start;
                        was_hyphen[j] = true;
                        line_hang_left[j] = hang_left;
                        line_hang_right[j] = hang_right;
                    }
                    continue;
                }

                if (t.kind == .glue) {
                    adj += t.adjustability;
                    natural += t.glue;
                } else {
                    natural += t.width;
                    natural_trim = natural;
                    content_count += 1;
                }
                if (first) {
                    hang_left = t.hang_left;
                    first = false;
                }
                hang_right = t.hang_right;

                if (!can_break[j] and j != n - 1) continue;
                const w = if (t.kind == .glue) natural_trim else natural;
                if (w > eff_measure + hang_left + hang_right) {
                    // 单个超长 token：允许溢出，但代价极高
                    if (content_count > 1) continue;
                }
                const d = lineDemerit(w, eff_measure + hang_left + hang_right, adj, break_penalty[j], prev_hyphen, j == n - 1);
                if (base + d < best[j]) {
                    best[j] = base + d;
                    prev[j] = start;
                    was_hyphen[j] = false;
                    line_hang_left[j] = hang_left;
                    line_hang_right[j] = hang_right;
                }
            }
        }

        // 回溯断行方案
        var ends = std.array_list.Managed(usize).init(self.allocator);
        var cur = n - 1;
        while (cur < n) {
            try ends.append(cur);
            if (cur == 0) break;
            const start = prev[cur];
            if (start == n or start == 0) break;
            cur = start - 1;
        }
        std.mem.reverse(usize, ends.items);

        for (ends.items) |e| {
            const start = if (prev[e] < n) prev[e] else e;
            var used_glue = std.array_list.Managed(usize).init(self.allocator);
            var natural: f64 = 0;
            var h: f64 = 0;
            var d: f64 = 0;
            var hyphenated = false;
            for (tokens[start .. e + 1], 0..) |t, k| {
                if (t.kind == .glue) {
                    natural += t.glue;
                    try used_glue.append(k);
                } else if (t.kind == .discretionary) {
                    hyphenated = true;
                    natural += t.width;
                } else {
                    natural += t.width;
                    h = @max(h, t.h + t.y_offset);
                    d = @max(d, t.d - t.y_offset);
                }
            }
            try lines.append(Line{
                .tokens = try self.allocator.dupe(Token, tokens[start .. e + 1]),
                .glue = try used_glue.toOwnedSlice(),
                .natural = natural,
                .height = h,
                .depth = d,
                .last = (e == n - 1),
                .hyphenated = hyphenated,
                .hang_left = line_hang_left[e],
                .hang_right = line_hang_right[e],
            });
        }

        return lines.toOwnedSlice();
    }

    fn mathPlainText(self: *Engine, node: math.Node) LayoutError![]const u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        switch (node) {
            .text => |s| try out.appendSlice(s),
            .glyph => |g| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(g.cp, &buf) catch 0;
                try out.appendSlice(buf[0..n]);
            },
            .row => |r| {
                for (r) |n| try out.appendSlice(try self.mathPlainText(n));
            },
            .tag => |t| try out.appendSlice(try self.mathPlainText(t.body.*)),
            else => {},
        }
        return out.toOwnedSlice();
    }

    fn lineDemerit(natural: f64, measure: f64, adj: f64, penalty: i32, prev_hyphen: bool, last: bool) f64 {
        if (measure <= 0) return 0;
        const delta = (measure - natural) / measure;
        var d: f64 = 0;
        if (last) {
            if (delta < 0) d = delta * delta * 10000.0;
        } else {
            d = (1.0 + adj) * delta * delta * 10000.0;
        }
        // TeX：demerit = (1 + adj) * badness + penalty（+ brokenpenalty）
        d += @as(f64, @floatFromInt(penalty));
        if (prev_hyphen) d += @as(f64, @floatFromInt(broken_penalty));
        return d;
    }

    fn estimateLines(text: []const u8, measure: f64, size: f64, family: fonts.Family) usize {
        const font = fonts.familyFont(family, .regular);
        const w = fonts.measure(text, font, size);
        if (measure <= 0) return 1;
        return @max(1, @as(usize, @intFromFloat(std.math.ceil(w / measure))));
    }
};

/// display 公式行末的 tag(...)（Typst 语义）
fn mathTag(nodes: []const math.Node) ?math.Tag {
    for (nodes) |node| {
        if (node == .tag) return node.tag;
    }
    return null;
}

fn isAllPunctuation(word: []const u8) bool {
    var view = std.unicode.Utf8View.init(word) catch return false;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (!isHangingPunctuation(cp)) return false;
    }
    return true;
}

fn appendRun(out: *std.array_list.Managed(Token), word: []const u8, font: fonts.Font, size: f64, color: Color, link: ?[]const u8, underline: bool, all_punct: bool, penalty: i32, breakable: bool, tracking: f64) LayoutError!void {
    if (word.len == 0) return;
    var hang: f64 = 0;
    if (all_punct) hang = size * 0.35;
    // 字距按字形数计入自然宽度：断行时字距同样参与可伸缩度的计算
    const glyphs = countGlyphs(word);
    try out.append(Token{
        .kind = .run,
        .text = word,
        .font = font,
        .size = size,
        .color = color,
        .link = link,
        .underline = underline,
        .width = fonts.measure(word, font, size) + tracking * @as(f64, @floatFromInt(glyphs)),
        .tracking = tracking,
        .h = fonts.ascent(font, size),
        .d = fonts.descent(font, size),
        // 纯标点不能开启新行：它必须附着在前一个词之后
        .breakable = breakable and !all_punct,
        .hanging = all_punct,
        .penalty = penalty,
        .hang_left = hang,
        .hang_right = hang,
    });
}

/// 单词中连续的字母部分（用于断词模式匹配）
fn alphabeticCore(word: []const u8) []const u8 {
    var start: usize = 0;
    while (start < word.len and !std.ascii.isLower(word[start])) start += 1;
    var end: usize = word.len;
    while (end > start and !std.ascii.isLower(word[end - 1])) end -= 1;
    return word[start..end];
}

/// 字形数（按码点计），字距按字形数累加
fn countGlyphs(word: []const u8) usize {
    var view = std.unicode.Utf8View.init(word) catch return word.len;
    var n: usize = 0;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |_| n += 1;
    return n;
}

/// CJK 行首禁则：这些标点不能出现在行首（其前面不允许断行）
fn isCjkNoBreakBefore(cp: u21) bool {
    return switch (cp) {
        0x3001, 0x3002, 0x3003, 0x3005, 0x3006, 0x3007, 0x3008, 0x3009, 0x300A, 0x300B, 0x3010, 0x3011, 0x3014, 0x3015, 0x3016, 0x3017, 0x3018, 0x3019, 0x301A, 0x301B, 0x301C, 0x301D, 0x301E, 0x301F, 0x3020, 0x3021, 0x3022, 0x3023, 0x3024, 0x3025, 0x3026, 0x3027, 0x3028, 0x3029, 0x3030, 0x303C, 0x303D, 0x303E, 0x303F, 0xFF01, 0xFF03, 0xFF05, 0xFF09, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1D, 0xFF61, 0xFF63, 0x2013, 0x2014, 0x2019, 0x201D, 0x2022, 0x2026, 0x203C, 0x203D, 0x2048, 0x2049 => true,
        else => false,
    };
}

/// CJK 行末禁则：这些标点不能出现在行末（其后不允许断行）
fn isCjkNoBreakAfter(cp: u21) bool {
    return switch (cp) {
        0x300C, 0x300D, 0x300E, 0x300F, 0x3012, 0x3013, 0x2018, 0x201C, 0xFF02, 0xFF1B, 0xFF62 => true,
        else => false,
    };
}

fn isHangingPunctuation(cp: u21) bool {
    return switch (cp) {
        0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026, 0x203C, 0x203D, 0x2048, 0x2049 => true,
        0x3001, 0x3002, 0x3005, 0x3006, 0x3007, 0x3008, 0x3009, 0x300A, 0x300B, 0x300C, 0x300D, 0x300E, 0x300F => true,
        0x3010, 0x3011, 0x3014, 0x3015, 0x3016, 0x3017, 0x3018, 0x3019, 0x301A, 0x301B, 0x301C, 0x301D, 0x301E, 0x301F, 0x3020, 0x3021, 0x3022, 0x3023, 0x3024, 0x3025, 0x3026, 0x3027, 0x3028, 0x3029, 0x302A, 0x302B, 0x302C, 0x302D, 0x302E, 0x302F, 0x3030, 0x3031, 0x3032, 0x3033, 0x3034, 0x3035, 0x3036, 0x3037, 0x303C, 0x303D, 0x303E, 0x303F => true,
        0xFF01, 0xFF05, 0xFF0C, 0xFF0E, 0xFF09, 0xFF1B, 0xFF1A, 0xFF1F, 0xFF61, 0xFF62, 0xFF63 => true,
        else => false,
    };
}

fn calloutColor(kind: ast.CalloutKind) Color {
    return switch (kind) {
        .note => .{ .r = 0.93, .g = 0.96, .b = 0.99 },
        .tip => .{ .r = 0.93, .g = 0.97, .b = 0.94 },
        .warning => .{ .r = 0.99, .g = 0.95, .b = 0.88 },
        .caution => .{ .r = 0.98, .g = 0.92, .b = 0.92 },
        .important => .{ .r = 0.95, .g = 0.94, .b = 0.99 },
    };
}

fn calloutAccent(kind: ast.CalloutKind) Color {
    return switch (kind) {
        .note => .{ .r = 0.16, .g = 0.36, .b = 0.78 },
        .tip => .{ .r = 0.18, .g = 0.55, .b = 0.34 },
        .warning => .{ .r = 0.72, .g = 0.45, .b = 0.12 },
        .caution => .{ .r = 0.8, .g = 0.16, .b = 0.16 },
        .important => .{ .r = 0.4, .g = 0.3, .b = 0.7 },
    };
}

fn cellWidth(cell: ast.Cell, size: f64, family: fonts.Family, variant: fonts.Variant) f64 {
    var total: f64 = 0;
    for (cell) |node| total += cellWidthOne(node, size, family, variant);
    return total;
}

/// 单元格不可断行的最小宽度：最长单词；CJK 逐字可断，取单个字形宽度
fn cellMinWidth(cell: ast.Cell, size: f64, family: fonts.Family, variant: fonts.Variant) f64 {
    var widest: f64 = 0;
    for (cell) |node| widest = @max(widest, cellMinWidthOne(node, size, family, variant));
    return widest;
}

fn cellMinWidthOne(node: ast.Inline, size: f64, family: fonts.Family, variant: fonts.Variant) f64 {
    switch (node) {
        .text => |s| {
            const font = fonts.familyFont(family, variant);
            var widest: f64 = 0;
            var iter = std.mem.splitAny(u8, s, " \t\n");
            while (iter.next()) |word| {
                if (word.len == 0) continue;
                if (cjkutil.hasNonAscii(word)) {
                    var view = std.unicode.Utf8View.init(word) catch {
                        widest = @max(widest, fonts.measure(word, font, size));
                        continue;
                    };
                    var it = view.iterator();
                    while (it.nextCodepoint()) |cp| widest = @max(widest, fonts.glyphWidth(cp, font, size));
                    continue;
                }
                widest = @max(widest, fonts.measure(word, font, size));
            }
            return widest;
        },
        .code => |s| return fonts.measure(s, fonts.familyFont(.mono, .regular), size * 0.9),
        .strong => |kids| {
            var w: f64 = 0;
            for (kids) |k| w += cellMinWidthOne(k, size, family, .bold);
            return w;
        },
        .em => |kids| {
            var w: f64 = 0;
            for (kids) |k| w += cellMinWidthOne(k, size, family, .italic);
            return w;
        },
        .math => |nodes| return @max(1, @as(f64, @floatFromInt(nodes.len)) * size * 0.5),
        else => return size * 0.5,
    }
}

fn cellWidthOne(node: ast.Inline, size: f64, family: fonts.Family, variant: fonts.Variant) f64 {
    switch (node) {
        .text => |s| return fonts.measure(s, fonts.familyFont(family, variant), size),
        .code => |s| return fonts.measure(s, fonts.familyFont(.mono, .regular), size * 0.9),
        .strong => |kids| {
            var w: f64 = 0;
            for (kids) |k| w += cellWidthOne(k, size, family, .bold);
            return w;
        },
        .em => |kids| {
            var w: f64 = 0;
            for (kids) |k| w += cellWidthOne(k, size, family, .italic);
            return w;
        },
        .math => |nodes| return @max(1, @as(f64, @floatFromInt(nodes.len)) * size * 0.5),
        else => return size * 0.5,
    }
}

test "engine: 基本分页" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = ast.Document{ .metadata = ast.Metadata{ .values = std.StringHashMap([]const u8).init(a) }, .content = &.{} };
    try doc.metadata.values.put("paper", "A4");
    const st = style.Style.fromMetadata(&doc.metadata);
    var e = Engine.init(a, &doc, st, null);
    const pages = try e.run();
    try std.testing.expect(pages.len >= 1);
}

test "engine: 行断行" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st = style.Style.defaults();
    var doc = ast.Document{ .metadata = ast.Metadata{ .values = std.StringHashMap([]const u8).init(a) }, .content = &.{} };
    var e = Engine.init(a, &doc, st, null);

    var tokens = std.array_list.Managed(Token).init(a);
    try e.pushText(&tokens, "the quick brown fox jumps over the lazy dog repeatedly many times", st.size, st.family, .regular, st.text_color, null, false);
    const lines = try e.breakTokens(tokens, 200);
    try std.testing.expect(lines.len > 1);
    for (lines) |line| {
        try std.testing.expect(line.natural <= 200.01);
    }
}
