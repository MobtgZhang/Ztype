// Ztype AST 节点类型定义
// 定义文档结构的抽象语法树

const std = @import("std");

// 词法分析器使用的 Token 类型
pub const TokenType = enum {
    newline,
    space,
    meta_start,
    meta_end,
    meta_delimiter,
    heading,
    script_start,
    script_end,
    block_start,
    directive_start,
    comment_start,
    comment_block_start,
    comment_block_end,
    table_pipe,
    list_dash,
    expr_start,
    expr_end,
    string,
    identifier,
    colon,
    block_separator,
    literal,
};

pub const Token = struct {
    type: TokenType,
    start: usize,
    end: usize,
    line: usize = 1,
    column: usize = 1,
    extra: union(enum) {
        none: void,
        heading_level: u8,
    } = .none,
};

pub const Document = struct {
    metadata: ?Metadata = null,
    content: std.array_list.Managed(Node),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{
            .content = std.array_list.Managed(Node).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Document) void {
        for (self.content.items) |*node| {
            node.deinit(self.allocator);
        }
        self.content.deinit();
        if (self.metadata) |*meta| {
            meta.deinit(self.allocator);
        }
    }
};

pub const Metadata = struct {
    pairs: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Metadata {
        return .{
            .pairs = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        var iter = self.pairs.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.pairs.deinit();
    }

    pub fn get(self: *const Metadata, key: []const u8) ?[]const u8 {
        return self.pairs.get(key);
    }
};

pub const Node = union(enum) {
    heading: Heading,
    paragraph: Paragraph,
    script_block: ScriptBlock,
    semantic_block: SemanticBlock,
    list: List,
    table: Table,
    page_directive: PageDirective,
    comment: Comment,

    pub fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .heading => |*h| h.deinit(allocator),
            .paragraph => |*p| p.deinit(allocator),
            .script_block => |*s| s.deinit(allocator),
            .semantic_block => |*sb| sb.deinit(allocator),
            .list => |*l| l.deinit(allocator),
            .table => |*t| t.deinit(allocator),
            .page_directive => |*pd| pd.deinit(allocator),
            .comment => {},
        }
    }
};

pub const Heading = struct {
    level: u8, // 1-4
    text: []const u8,
    id: ?[]const u8 = null,

    pub fn deinit(self: *Heading, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        if (self.id) |id| allocator.free(id);
    }
};

pub const Paragraph = struct {
    spans: std.array_list.Managed(Span),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Paragraph {
        return .{
            .spans = std.array_list.Managed(Span).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Paragraph, allocator: std.mem.Allocator) void {
        for (self.spans.items) |*span| {
            span.deinit(allocator);
        }
        self.spans.deinit();
    }
};

pub const Span = union(enum) {
    text: []const u8,
    bold: []const u8,
    italic: []const u8,
    code: []const u8,
    link: Link,
    expr: []const u8, // @(expr)
    ref_id: []const u8, // [->id]
    footnote: []const u8,

    pub fn deinit(self: *Span, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text, .bold, .italic, .code, .expr, .ref_id, .footnote => |s| allocator.free(s),
            .link => |*l| l.deinit(allocator),
        }
    }
};

pub const Link = struct {
    text: []const u8,
    url: []const u8,

    pub fn deinit(self: *Link, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.url);
    }
};

pub const ScriptBlock = struct {
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScriptBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.source);
    }
};

pub const SemanticBlock = struct {
    block_type: []const u8,
    modifier: ?[]const u8 = null, // e.g. "zig" for code
    attrs: std.StringHashMap([]const u8),
    content: ?[]const u8 = null,
    children: std.array_list.Managed(Node),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SemanticBlock {
        return .{
            .block_type = "",
            .attrs = std.StringHashMap([]const u8).init(allocator),
            .children = std.array_list.Managed(Node).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SemanticBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.block_type);
        if (self.modifier) |m| allocator.free(m);
        var iter = self.attrs.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.attrs.deinit();
        if (self.content) |c| allocator.free(c);
        for (self.children.items) |*node| {
            node.deinit(allocator);
        }
        self.children.deinit();
    }
};

pub const List = struct {
    items: std.array_list.Managed(Paragraph),
    ordered: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) List {
        return .{
            .items = std.array_list.Managed(Paragraph).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *List, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            item.deinit(allocator);
        }
        self.items.deinit();
    }
};

pub const Table = struct {
    caption: ?[]const u8 = null,
    id: ?[]const u8 = null,
    headers: std.array_list.Managed([]const u8),
    alignments: std.array_list.Managed(Alignment),
    rows: std.array_list.Managed(std.array_list.Managed([]const u8)),
    allocator: std.mem.Allocator,

    pub const Alignment = enum { left, center, right };

    pub fn init(allocator: std.mem.Allocator) Table {
        return .{
            .headers = std.array_list.Managed([]const u8).init(allocator),
            .alignments = std.array_list.Managed(Alignment).init(allocator),
            .rows = std.array_list.Managed(std.array_list.Managed([]const u8)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        if (self.caption) |c| allocator.free(c);
        if (self.id) |id| allocator.free(id);
        for (self.headers.items) |h| allocator.free(h);
        self.headers.deinit();
        self.alignments.deinit();
        for (self.rows.items) |*row| {
            for (row.items) |cell| allocator.free(cell);
            row.deinit();
        }
        self.rows.deinit();
    }
};

pub const PageDirective = struct {
    kind: []const u8,
    args: []const u8,

    pub fn deinit(self: *PageDirective, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.args);
    }
};

pub const Comment = struct {
    content: []const u8,
};
