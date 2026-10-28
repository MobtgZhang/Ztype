//! Ztype AST 定义
//! 文档结构：元数据 + 块级节点；块内含行内节点

const std = @import("std");
const math = @import("math.zig");

pub const Metadata = struct {
    values: std.StringHashMap([]const u8),

    pub fn get(self: *const Metadata, key: []const u8) ?[]const u8 {
        return self.values.get(key);
    }

    pub fn getOr(self: *const Metadata, key: []const u8, default: []const u8) []const u8 {
        return self.values.get(key) orelse default;
    }
};

pub const Document = struct {
    metadata: Metadata,
    content: []Block,
};

pub const Inline = union(enum) {
    text: []const u8,
    strong: []Inline,
    em: []Inline,
    code: []const u8,
    link: Link,
    ref: []const u8, // [->id]
    footnote: []Inline, // [^note]
    math: []math.Node, // $...$
    expr: []const u8, // @(expr)
    sup: []Inline,
    sub: []Inline,
    cite: []const u8, // [@key] 引文
};

pub const Link = struct {
    text: []Inline,
    url: []const u8,
};

pub const Paragraph = struct {
    content: []Inline,
};

pub const Heading = struct {
    level: u8,
    text: []Inline,
    id: ?[]const u8 = null,
    number: ?[]const u8 = null,
};

pub const ListItem = struct {
    content: []Inline,
    children: []ListItem = &.{},
};

pub const List = struct {
    items: []ListItem,
    ordered: bool = false,
};

pub const Quote = struct {
    content: []Block,
    source: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

pub const CodeBlock = struct {
    language: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    id: ?[]const u8 = null,
    number: ?[]const u8 = null,
    source: []const u8,
};

pub const Figure = struct {
    src: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    caption: ?[]const u8 = null,
    id: ?[]const u8 = null,
    number: ?[]const u8 = null,
    width: ?f64 = null,
};

pub const Alignment = enum { left, center, right };

/// 列宽：`auto` 按内容自然宽度分配，`length` 为绝对长度（pt），
/// `fraction` 为版心百分比，`fr` 为剩余空间的分配权重（Typst 的 1fr）
pub const ColumnWidth = union(enum) {
    auto: void,
    length: f64,
    fraction: f64,
    fr: f64,
};

/// 单元格：一组行内节点（这样表格单元格里也能出现粗体、公式等）
pub const Cell = []Inline;
/// 行：一组单元格
pub const Row = []Cell;

pub const Table = struct {
    caption: ?[]const u8 = null,
    id: ?[]const u8 = null,
    number: ?[]const u8 = null,
    headers: Row = &.{},
    alignments: []Alignment = &.{},
    /// 与 alignments 等长：对齐行中可写 `<2cm`、`^30%`、`>2fr`
    widths: []ColumnWidth = &.{},
    rows: []Row = &.{},
};

pub const CalloutKind = enum { note, warning, tip, caution, important };

pub const Callout = struct {
    kind: CalloutKind,
    title: ?[]const u8 = null,
    content: []Block,
    id: ?[]const u8 = null,
    caption: ?[]const u8 = null,
};

pub const MathBlock = struct {
    source: []const u8,
    nodes: []math.Node,
    id: ?[]const u8 = null,
    number: ?[]const u8 = null,
    caption: ?[]const u8 = null,
};

pub const Definition = struct {
    term: []Inline,
    definition: []Inline,
};

pub const DefinitionList = struct {
    entries: []Definition,
};

pub const BibEntry = struct {
    key: []const u8,
    text: []Inline,
    id: ?[]const u8 = null,
};

pub const Bibliography = struct {
    entries: []BibEntry,
    title: ?[]const u8 = null,
    id: ?[]const u8 = null,
};

pub const ScriptBlock = struct {
    source: []const u8,
};

pub const Block = union(enum) {
    heading: Heading,
    paragraph: Paragraph,
    list: List,
    quote: Quote,
    code: CodeBlock,
    figure: Figure,
    table: Table,
    callout: Callout,
    math: MathBlock,
    definition_list: DefinitionList,
    bibliography: Bibliography,
    page_break: void,
    column_break: void,
    rule: void,
    toc: void,
    script: ScriptBlock,
};
